{- |
Module: Blockchain.Fae.Internal.Storage
Description: Storage of contracts and transactions
Copyright: (c) Ryan Reich, 2017
License: MIT
Maintainer: ryan.reich@gmail.com
Stability: experimental

This module provides the 'FaeStorageT' monad family, which tracks the state of Fae as contracts execute.  All the types here are parametrized over an unconstrained parameter @c@, but only 'AbstractContract' is ever used.  This indirection is necessary to avert an import cycle between this module and "Blockchain.Fae.Internal.Contract".
-}
{-# LANGUAGE TemplateHaskell #-}
module Blockchain.Fae.Internal.Storage where

import Blockchain.Fae.Internal.Crypto
import Blockchain.Fae.Internal.Exceptions
import Blockchain.Fae.Internal.IDs
import Blockchain.Fae.Internal.Lens
import Blockchain.Fae.Internal.Versions

import Control.Monad.IO.Class
import Control.Monad.State

import Data.Dynamic
import Data.IntMap (IntMap)
import Data.List
import Data.Map (Map)
import Data.Maybe
import Data.Serialize
import Data.Typeable

import qualified Data.IntMap as IntMap
import qualified Data.Map as Map

-- * Types

-- | Storage is just an association between transactions and what they did.
newtype StorageT c =
  Storage 
  { 
    getStorage :: Map TransactionID (TransactionEntryT c)
  }

-- | Each transaction can produce outputs in two different ways (cf.
-- 'ContractID'), has an associated "signer" public key, and a result,
-- which can be anything, but should be 'show'able so that it has outside
-- meaning.  This is an existential type, so the record names are just
-- there for documentation; values have to be extracted by
-- pattern-matching.
--
-- The technical reason for separating 'inputOutputs' from 'outputs' is
-- that it makes it possible for contracts to create new contracts without
-- putting a global lock on the storage; thunk execution will go straight
-- to the correct contract's outputs and not do any other contract's or the
-- transaction's direct outputs.
data TransactionEntryT c =
  forall a. (Show a) =>
  TransactionEntry 
  {
    inputOutputs :: InputOutputsT c,
    inputOrder :: [ShortContractID],
    outputs :: OutputsT c,
    signers :: Signers,
    result :: a
  }

-- | Inputs are identified by 'ShortContractID's so that 'ContractIDs' of
-- the 'InputOutput' variant can be flat, rather than nested potentially
-- indefinitely.
type InputOutputsT c = Map ShortContractID (InputOutputVersionsT c)
-- | We save the versions map, with the actual values scrubbed, so that it
-- can be displayed to learn the actual version IDs.
data InputOutputVersionsT c =
  InputOutputVersions
  {
    iRealID :: ContractID,
    iOutputs :: OutputsT c,
    iVersions :: Map VersionID TypeRep
  }
-- | Outputs are ordered by creation.  However, contracts can be deleted,
-- and deletion must preserve the original ordering index of the remaining
-- contracts, so it's not enough to just store them in a sequence.  The
-- second field is the "nonce" of a contract, the number of times it has
-- been called, used for security.
type OutputsT c = IntMap (c, Int)
-- | Transactions can have many named signatories.
type Signers = Map String PublicKey
-- | The storage monad is just a state monad.  It has to be over 'IO' both
-- because we need to catch exceptions, and because the interpreter has to
-- be in a 'MonadIO'.
newtype FaeStorageT c a = FaeStorage {getFaeStorage :: StateT (StorageT c) IO a}
  deriving 
  (
    Functor, Applicative, Monad, 
    MonadThrow, MonadCatch, MonadMask,
    MonadIO
  )

-- | Just making it easier to use this monad.
deriving instance MonadState (StorageT c) (FaeStorageT c)

-- | Exceptions for storage-related errors.
data StorageException =
  BadTransactionID TransactionID |
  BadContractID ContractID |
  BadInputID ShortContractID |
  BadNonce ContractID Int Int |
  InvalidNonceAt ContractID
  deriving (Typeable, Show)

-- * Template Haskell

makeLenses ''StorageT
makeLenses ''TransactionEntryT
makeLenses ''InputOutputVersionsT

{- Instances -}

-- | Of course
instance Exception StorageException

-- | For the 'At' instance
type instance Index (StorageT c) = ContractID
-- | For the 'At' instance
type instance IxValue (StorageT c) = c
-- | For the 'At' instance
instance Ixed (StorageT c)
-- | We define this instance /in addition to/ the natural 'TransactionID'
-- indexing of a 'StorageT' so that we can look up contracts by ID, which
-- requires descending to various levels into the maps.
instance At (StorageT c) where
  at cID@((_ :# n) :# m) = throw $ InvalidContractID cID
  at (cID :# n) = nonceAt cID . checkNonce cID (Just n)
  at cID = nonceAt cID . checkNonce cID Nothing

-- * Functions

-- | Like 'at', but retaining the nonce
nonceAt :: ContractID -> Lens' (StorageT c) (Maybe (c, Int))
nonceAt cID@(JustTransaction txID) = throw (BadContractID cID)
nonceAt cID@(TransactionOutput txID i) =
  _getStorage .
  at txID .
  defaultLens (throw $ BadTransactionID txID) .
  _outputs .
  at i
nonceAt cID@(InputOutput txID sID i) = 
  _getStorage .
  at txID .
  defaultLens (throw $ BadTransactionID txID) .
  _inputOutputs .
  at sID .
  defaultLens (throw $ BadInputID sID) .
  _iOutputs .
  at i
nonceAt cID = throw $ InvalidNonceAt cID

-- | Enforces nonce-correctness when it is required
checkNonce :: 
  ContractID -> Maybe Int -> Lens' (Maybe (a, Int)) (Maybe a)
checkNonce _ Nothing = lens (fmap fst) nonceSetter
checkNonce cID (Just n) = lens (fmap $ \(x, m) -> f m x) checkNonceSetter where
  checkNonceSetter xM@(Just (_, m)) yM = f m $ nonceSetter xM yM
  checkNonceSetter Nothing yM = nonceSetter Nothing yM
  f :: Int -> b -> b
  f m x = if m == n then x else throw $ BadNonce cID m n

-- | Updating a contract entry nonce-correctly
nonceSetter :: Maybe (a, Int) -> Maybe a -> Maybe (a, Int)
nonceSetter (Just (x, m)) (Just y) = Just (y, m + 1)
nonceSetter Nothing (Just y) = Just (y, 0)
nonceSetter _ _ = Nothing

-- | Just an 'IntMap' constructor, indexing consecutively from 0.
intMapList :: [a] -> IntMap (a, Int)
intMapList = IntMap.fromList . zip [0 ..] . flip zip (repeat 0)

-- | Convenience function for neatly showing a 'TransactionEntry' by ID,
-- rather than actually going into the storage to get and format it.  It
-- catches all exceptions thrown by contracts or transactions and prints
-- an error message instead; thus, whatever actually did complete is part
-- of the output.
showTransaction :: forall c. TransactionID -> FaeStorageT c String
showTransaction txID = do
  TransactionEntry ios ino os ss x <- use $
    _getStorage . at txID . defaultLens (throw $ BadTransactionID txID)
  resultSafe <- displayException show x
  outputsSafe <- displayException (show . IntMap.keys) os
  inputsSafe <- forM ino $ \sID -> do
    let 
      iov = 
        fromMaybe (error $ "Contract ID " ++ show sID ++ " missing") $ 
        Map.lookup sID ios
    n <- handleAll (return . throw) $ showNonce iov
    iovS <- displayException (showIOVersions n) iov
    return (sID, iovS)
  return $ 
    intercalate "\n  " $
      ("Transaction " ++ show txID) :
      ("result: " ++ resultSafe) :
      ("outputs: " ++ outputsSafe) :
      prettySigners ss :
      (flip map inputsSafe $ uncurry $
        \sID str -> "input " ++ show sID ++ "\n    " ++ str)
  where 
    displayException f x = liftIO $
      catchAll (f <$> evaluate x) $ \e -> return $ "<exception> " ++ show e
    showNonce iov = 
      case iov of
        InputOutputVersions{..} -> 
          use $ nonceAt iRealID . defaultLens (undefined, -1) . to (show . snd)
    showOutputs os = "outputs: " ++ show (IntMap.keys os)
    showIOVersions nS InputOutputVersions{..} = intercalate "\n    " $
      [
        "nonce: " ++ nS, 
        showOutputs iOutputs,
        prettyVersions iVersions
      ]
    prettySigners =
      intercalate "\n    " .
      ("signers:" :) .
      map (\(name, key) -> name ++ ": " ++ show key) .
      Map.toList 
    prettyVersions =
      intercalate "\n      " .
      ("versions:" :) .
      map (\(vID, tRep) -> show vID ++ ": " ++ show tRep) .
      Map.toList 

