module PostTX.Faeth where

import Blockchain.Fae.FrontEnd

import Common.Lens
import Common.ProtocolT

import Control.Monad.Trans

import Data.Aeson (ToJSON(..))
import Data.Maybe

import PostTX.Args
import PostTX.TXSpec

import System.Console.Haskeline

import Text.Read

newtype GetFaethTX = GetFaethTX EthTXID

instance ToJSON GetFaethTX where
  toJSON (GetFaethTX ethTXID) = toJSON [ethTXID]

instance ToRequest GetFaethTX where
  requestMethod _ = "eth_getTransactionByHash"

submitFaeth :: String -> Maybe Integer -> Maybe EthAddress -> TXSpec -> IO ()
submitFaeth host valM faethTo TXSpec{specModules = LoadedModules{..}, ..} = do
  senderEthAccount <- inputAccount
  runProtocolT $ do
    ethTXID <- sendReceiveProtocolT 
      FaethTXData
      {
        faeTX = txMessage, 
        mainModule = snd mainModule, 
        faethEthValue = HexInteger <$> valM,
        faethEthAddress = fromMaybe (address senderEthAccount) faethTo,
        ..
      }
    liftIO . putStrLn $ 
      "Ethereum transaction ID: " ++ ethTXID ++
      "\nFae transaction ID: " ++ show (getTXID txMessage)

resubmitFaeth :: String -> EthTXID -> FaethArgs -> IO ()
resubmitFaeth host ethTXID FaethArgs{..} = do
  senderEthAccount <- inputAccount
  runProtocolT $ do
    faethTXData <- sendReceiveProtocolT $ GetFaethTX ethTXID
    newKeys <- liftIO $ mapM resolveKeyName newKeyNames
    let 
      addSigners =
        foldr (.) id $
        zipWith addSigner newNames newKeys
    ethTXID <- sendReceiveProtocolT $
      faethTXData
      & _faeTX %~ addSigners
      & _senderEthAccount .~ senderEthAccount
      & _faethEthAddress .~ fromMaybe (address senderEthAccount) faethTo
      & _faethEthValue .~ (HexInteger <$> faethValue)
    liftIO . putStrLn $
      "New Ethereum transaction ID: " ++ ethTXID ++
      "\nfor Fae transaction: " ++ show (getTXID $ faeTX faethTXData)

  where (newNames, newKeyNames) = unzip newSigners

addSigner :: String -> Either PublicKey PrivateKey -> TXMessage -> TXMessage
addSigner _ (Left _) = id
addSigner name (Right privKey) = signTXMessage name privKey

inputAccount :: IO EthAccount
inputAccount = runInputT defaultSettings $ 
  EthAccount <$> inputAddress <*> inputPassphrase

inputAddress :: InputT IO EthAddress
inputAddress = do
  addressSM <- getInputLine "Ethereum address: "
  let addressM = addressSM >>= readMaybe
  maybe (error "Bad address") return addressM

inputPassphrase :: InputT IO String
inputPassphrase = do
  passphraseM <- getInputLine "Passphrase: "
  maybe (error "Bad passphrase") return passphraseM