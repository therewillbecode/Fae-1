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

-- | The public key for our cryptographic algorithm.
data PublicKey = PublicKey deriving (Eq, Show)
data Signature = Signature
type Digest = Hash.Digest Hash.SHA3_256

class Digestible a where
  digest :: a -> Digest

  default digest :: (Serialize a) => a -> Digest
  digest = Hash.hash . Ser.encode

instance Serialize Digest where
  put = Ser.putByteString . BA.convert
  get = Ser.isolate hashSize $ do
    digestBS <- Ser.getBytes hashSize
    let Just result = Hash.digestFromByteString digestBS
    return result
    where hashSize = Hash.hashDigestSize Hash.SHA3_256

instance Digestible Digest
instance (Serialize a) => Digestible [a]

signer :: Signature -> a -> PublicKey
signer = undefined

nullDigest :: Digest
nullDigest = Hash.hash (BA.empty :: BA.Bytes)
