import Data.Functor.Identity

body :: Transaction (Identity (PublicKey, PublicKey)) (PublicKey, PublicKey)
body (Identity keyPair) = return keyPair