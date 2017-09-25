module Blockchain.Fae.Internal.Transaction where

import Blockchain.Fae.Internal.Contract
import Blockchain.Fae.Internal.Coroutine
import Blockchain.Fae.Internal.Crypto
import Blockchain.Fae.Internal.Exceptions
import Blockchain.Fae.Internal.IDs
import Blockchain.Fae.Internal.Lens
import Blockchain.Fae.Internal.MonadFae
import Blockchain.Fae.Internal.Reward
import Blockchain.Fae.Internal.Storage

import Control.Monad
import Control.Monad.RWS
import Control.Monad.State

import Data.Dynamic
import Data.Foldable
import Data.Maybe
import Data.Sequence (Seq)
import Data.Typeable

import qualified Data.IntMap as IntMap
import qualified Data.Map as Map
import qualified Data.Sequence as Seq

import GHC.Generics hiding (to)
import qualified GHC.Generics as Gen (to)

import Debug.Trace

{- Types -}

data InputArg =
  LiteralArg Dynamic |
  TrustedArg Int

-- | Similar to the 'Contract' type but disallows 'release' and 'spend'.
-- Unlike contracts, the return values of transactions are not used in
-- contract code, but stored for external reference.  Thus, they need not
-- (and cannot) bear value.
type Transaction inputs a = inputs -> FaeTX a

type Storage = StorageT AbstractContract
type InputOutputs = InputOutputsT AbstractContract
type FaeStorage = FaeStorageT AbstractContract

{- Typeclasses -}

class GetInputValues a where
  getInputValues :: [Dynamic] -> a
  default getInputValues :: 
    (Generic a, GGetInputValues (Rep a)) => [Dynamic] -> a
  getInputValues s
    | null s' = Gen.to x
    | otherwise = throw TooManyInputs
    where (x, s') = runState gGetInputValues s

class GGetInputValues f where
  gGetInputValues :: State [Dynamic] (f p)

{- Instances -}

instance GGetInputValues U1 where
  gGetInputValues = return U1

instance (GGetInputValues f, GGetInputValues g) => GGetInputValues (f :*: g) where
  gGetInputValues = do
    l <- gGetInputValues
    r <- gGetInputValues
    return $ l :*: r

instance (Typeable c) => GGetInputValues (K1 i c) where
  gGetInputValues = do
    s <- get
    case s of
      [] -> throw NotEnoughInputs
      xDyn : s' -> do
        put s'
        return $ K1 $ fromDyn xDyn $
          throw $ BadArgType (typeRep (Proxy @c)) (dynTypeRep xDyn)

instance (GGetInputValues f) => GGetInputValues (M1 i t f) where
  gGetInputValues = M1 <$> gGetInputValues

{- Functions -}

runTransaction :: 
  forall inputs a result.
  (GetInputValues inputs, Typeable a) =>
  TransactionID -> PublicKey -> Bool ->
  Seq (ContractID, InputArg) -> 
  Transaction inputs a -> FaeStorage a
runTransaction txID txKey isReward inputArgs f = handleAll placeException $
  state $ 
    runFaeContract txID txKey .
    transaction txID isReward inputArgs f 
  where
    placeException e = do
      _getStorage . at txID ?=
        TransactionEntry
        {
          inputOutputs = throw e,
          outputs = throw e,
          result = throw e
        }
      return $ throw e

runFaeContract :: TransactionID -> PublicKey -> FaeContract Naught a -> a
runFaeContract txID txKey =
  fst .
  (\r s m -> evalRWS m r s) txKey (txID, 0) .
  unWrapped . 
  flip evalStateT Map.empty .
  runCoroutine

transaction :: 
  (GetInputValues inputs, Typeable a) =>
  TransactionID ->
  Bool -> 
  Seq (ContractID, InputArg) -> 
  Transaction inputs a -> 
  Storage -> FaeContract Naught (a, Storage)
transaction txID isReward inputArgs f storage = do
  (inputs0, storage', inputOutputs) <- runInputContracts inputArgs storage
  inputs <- withReward inputs0
  (result0, outputsL) <- listen $ getFae $ f $ getInputValues $ toList inputs
  let 
    result = toDyn result0
    outputs = intMapList outputsL
  escrows <- get
  unless (Map.null escrows) $ throw OpenEscrows
  let newStorage = storage' & _getStorage . at txID ?~ TransactionEntry{..}
  return (result0, newStorage)

  where
    withReward inputs
      | isReward = do
          eID <- newEscrow [] rewardEscrow
          return $ inputs |> toDyn eID
      | otherwise = return inputs

runInputContracts ::
  (Functor s) =>
  Seq (ContractID, InputArg) ->
  Storage ->
  FaeContract s (Seq Dynamic, Storage, InputOutputs)
runInputContracts inputArgs storage = 
  (\x s f -> foldl f x s) (return (Seq.empty, storage, Map.empty)) inputArgs $
  \accM (cID, arg) -> do
    (results, storage, inputOutputs) <- accM
    let results' = Seq.zip (fst <$> inputArgs) results
    ((gAbsM, result), outputsL) <- listen $ callContract results' storage cID arg
    censor (const []) $ return
      (
        results |> result,
        storage & at cID %~ liftM2 (_abstractContract .~) gAbsM,
        inputOutputs & at (shorten cID) ?~ intMapList outputsL
      )

callContract :: 
  (Functor s) =>
  Seq (ContractID, Dynamic) -> Storage -> ContractID -> InputArg ->
  FaeContract s (Maybe AbstractContract, Dynamic)
callContract results storage cID arg = fAbs realArg
  where
    Trusted (ConcreteContract fAbs) trusts = 
      storage ^. at cID . defaultLens (throw $ BadInput cID)
    realArg = case arg of
      LiteralArg xDyn -> xDyn
      TrustedArg i -> getRealArg cID trusts results i

getRealArg :: 
  ContractID -> [ShortContractID] -> Seq (ContractID, Dynamic) -> Int -> Dynamic
getRealArg cID trusts results i
  | shorten chainID `elem` trusts = chainVal
  | otherwise = throw $ UntrustedInput cID chainID
  where 
    (chainID, chainVal) = 
      fromMaybe (throw $ BadChainedInput cID i) (results Seq.!? i)

