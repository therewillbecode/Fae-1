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
import Data.Maybe
import Data.Sequence (Seq)
import Data.Typeable

import qualified Data.Map as Map
import qualified Data.Sequence as Seq

{- Types -}

data InputArg =
  LiteralArg Dynamic |
  TrustedArg Int

newtype Inputs = Inputs (Seq Dynamic)
type Transaction a = Inputs -> FaeTX a

type Storage = StorageT AbstractContract
type InputOutputs = InputOutputsT AbstractContract
type FaeStorage = FaeStorageT AbstractContract

{- Functions -}

runTransaction :: 
  forall a result.
  (Typeable a) =>
  TransactionID -> PublicKey -> Bool ->
  Seq (ContractID, InputArg) -> 
  Transaction a -> FaeStorage a
runTransaction txID txKey isReward inputArgs f = state $ 
  runFaeContract txID txKey . 
  transaction txID isReward inputArgs f 

runFaeContract :: TransactionID -> PublicKey -> FaeContract Naught a -> a
runFaeContract txID txKey =
  fst .
  (\r s m -> evalRWS m r s) txKey (txID, 0) .
  unWrapped . 
  flip evalStateT Map.empty .
  runCoroutine

transaction :: 
  (Typeable a) =>
  TransactionID ->
  Bool -> 
  Seq (ContractID, InputArg) -> 
  Transaction a -> 
  Storage -> FaeContract Naught (a, Storage)
transaction txID isReward inputArgs f storage = do
  (inputs0, storage', inputOutputs) <- runInputContracts inputArgs storage
  inputs <- withReward inputs0
  (result0, outputsL) <- listen $ getFae $ f (Inputs inputs)
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
    let 
      realArg = case arg of
        LiteralArg xDyn -> xDyn
        TrustedArg i -> 
          fromMaybe (throw $ BadChainedInput cID i) (results Seq.!? i) 
      ConcreteContract fAbs = 
        storage ^. 
        at cID . defaultLens (throw $ BadInput cID) . 
        _abstractContract
    ((gAbsM, result), outputsL) <- listen $ fAbs realArg
    censor (const []) $ return
      (
        results |> result,
        storage & at cID %~ liftM2 (_abstractContract .~) gAbsM,
        inputOutputs & at (shorten cID) ?~ intMapList outputsL
      )

