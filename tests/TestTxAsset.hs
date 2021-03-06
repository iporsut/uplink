{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module TestTxAsset (
  txAssetTests,
) where

import Protolude

import Test.Tasty
import Test.QuickCheck.Monadic
import qualified Test.Tasty.QuickCheck as QC
import qualified Data.ByteString.Char8 as BS

import qualified Data.Map as Map
import qualified Block
import qualified Config
import qualified Transaction
import qualified Account
import qualified Ledger
import qualified Validate
import qualified Asset
import qualified DB
import qualified Key
import qualified NodeState
import qualified Time
import qualified Derivation
import qualified Network.P2P.Message as Message
import qualified Network.P2P.Cmd as Cmd

import qualified Reference as Ref

txAssetTests :: IO DB.Databases -> TestTree
txAssetTests getDBs =
  testGroup "TxAsset tests"
    [ QC.testProperty "TxAsset" $ \k -> monadicIO $ do

        let initWorld = Ledger.genesisWorld

        -- create accounts
        (acc1, keys1) <- run $ Account.newAccount "GMT" $ Map.fromList [("Num", BS.pack $ show (k :: Int))]
        (acc2, keys2) <- run $ Account.newAccount "GMT+1" $ Map.fromList [("Num", BS.pack $ show (k+1))]

        let Right accWorld = Ledger.addAccount acc2 =<< Ledger.addAccount acc1 initWorld

        -- create asset
        let acc1PrivKey = snd keys1
            addr1       = Account.address acc1
            addr2       = Account.address acc2
            -- testAsset1 supply: 1000000
            testAsset   = Ref.testAsset1 { Asset.issuer = addr1 }
        sig <- run $ Key.signS acc1PrivKey testAsset
        let assetAddr = Derivation.addrAsset sig (Asset.issuedOn testAsset) (Asset.issuer testAsset)
        let Right assetWorld = Ledger.addAsset assetAddr testAsset accWorld

        -- transfer helper function
        let mkTransferTx from to amnt world = do
              let hdr = Transaction.TxAsset (Transaction.Transfer assetAddr to amnt)
              tx <- run $ Transaction.newTransaction from Nothing acc1PrivKey hdr
              -- XXX Initialize ApplyCtx in a better way
              genesisBlk <- run Ref.testGenesis
              let applyCtx = Validate.ApplyCtx genesisBlk addr1 acc1PrivKey
              run $ Validate.applyTransactions applyCtx world [tx]

        -- Transfer Asset supply to issuer holdings:
        (world1, errs1, _) <- mkTransferTx addr1 addr1 50000 assetWorld
        assert $ null errs1

        -- Transfer issuer holdings to addr2:
        (world2, errs2, _ ) <- mkTransferTx addr1 addr2 25000 world1
        assert $ null errs2

        -- Give too much supply to addr1
        (world3, errs3, _) <- mkTransferTx addr1 addr1 100000 world2
        assert $ not $ null errs3

        -- Transfer too much from addr2 to addr1
        (world4, errs4, _) <- mkTransferTx addr2 addr1 25001 world3
        assert $ not $ null errs4

        -- Assert holdings are correct:
        let correctHoldings = Map.fromList [(addr1, 25000), (addr2, 25000)]
        let (Right holdings) = Asset.holdings <$> Ledger.lookupAsset assetAddr world4
        assert $ correctHoldings == holdings

    ]
