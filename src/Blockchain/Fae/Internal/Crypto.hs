module Blockchain.Fae.Internal.Crypto 
  (
    Serialize,
    module Blockchain.Fae.Internal.Crypto
  ) where

import qualified Crypto.Hash as Hash

import qualified Data.ByteArray as BA
import Data.Dynamic
import Data.Serialize (Serialize)

import qualified Data.Serialize as Ser
import qualified Data.Serialize.Put as Ser
import qualified Data.Serialize.Get as Ser

data PublicKey = PublicKey deriving (Eq)
data Signature = Signature
type Digest = Hash.Digest Hash.SHA3_256

class Digestible a where
  digest :: a -> Digest
  digestWith :: Digest -> a -> Digest

  default digest :: (Serialize a) => a -> Digest
  digest = Hash.hash . Ser.encode

  default digestWith :: (Serialize a) => Digest -> a -> Digest
  digestWith d x = 
    Hash.hashFinalize $ 
    Hash.hashUpdates Hash.hashInit $
    [BA.convert d, Ser.encode x] 

instance Serialize Digest where
  put = Ser.putByteString . BA.convert
  get = Ser.isolate hashSize $ do
    digestBS <- Ser.getBytes hashSize
    let Just result = Hash.digestFromByteString digestBS
    return result
    where hashSize = Hash.hashDigestSize Hash.SHA3_256

instance Digestible Digest

signer :: Signature -> a -> PublicKey
signer = undefined
