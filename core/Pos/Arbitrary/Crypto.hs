-- | `Arbitrary` instances for using in tests and benchmarks

module Pos.Arbitrary.Crypto
       ( SharedSecrets (..)

       , arbitraryEncSecretKey
       , arbitraryMostlyUnencryptedKeys
       ) where

import           Universum

import           Control.Monad                     (zipWithM)
import           Crypto.Random                     (getRandomBytes)
import qualified Data.ByteArray                    as ByteArray
import qualified Data.ByteString                   as BS
import           Data.List.NonEmpty                (fromList)
import           Test.QuickCheck                   (Arbitrary (..), Gen, elements,
                                                    frequency, oneof, vector, vectorOf)
import           Test.QuickCheck.Arbitrary.Generic (genericArbitrary, genericShrink)

import           Pos.Arbitrary.Crypto.Unsafe       ()
import           Pos.Binary.Class                  (AsBinary (..), AsBinaryClass (..), Bi)
import           Pos.Binary.Crypto                 ()
import           Pos.Core.Configuration.Protocol   (HasProtocolConstants)
import           Pos.Crypto.AsBinary               ()
import           Pos.Crypto.Hashing                (AbstractHash, HashAlgorithm)
import           Pos.Crypto.HD                     (HDAddressPayload, HDPassphrase (..))
import           Pos.Crypto.Random                 (deterministic, randomNumberInRange)
import           Pos.Crypto.SecretSharing          (DecShare, EncShare, Secret,
                                                    SecretProof, Threshold, VssKeyPair,
                                                    VssPublicKey, decryptShare,
                                                    genSharedSecret, toVssPublicKey,
                                                    vssKeyGen)
import           Pos.Crypto.Signing                (ProxyCert, ProxySecretKey,
                                                    ProxySignature, PublicKey, SecretKey,
                                                    Signature, Signed,
                                                    deterministicKeyGen, keyGen, mkSigned,
                                                    proxySign, sign, toPublic)
import           Pos.Crypto.Signing.Redeem         (RedeemPublicKey, RedeemSecretKey,
                                                    RedeemSignature, redeemKeyGen,
                                                    redeemSign)
import           Pos.Crypto.Signing.Safe           (EncryptedSecretKey, PassPhrase,
                                                    createProxyCert, createPsk,
                                                    emptyPassphrase, noPassEncrypt,
                                                    passphraseLength, safeKeyGen)
import           Pos.Crypto.Signing.Types.Tag      (SignTag (..))
import           Pos.Util.Arbitrary                (NonCached (..), Nonrepeating (..),
                                                    arbitraryUnsafe, sublistN)

{- A note on 'Arbitrary' instances
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Generating keys takes time, so we just pregenerate lots of keys in advance
and use them in 'Arbitrary' instances.
-}

keysToGenerate :: Int
keysToGenerate = 128

----------------------------------------------------------------------------
-- SignTag
----------------------------------------------------------------------------

instance Arbitrary SignTag where
    arbitrary = genericArbitrary
    shrink = genericShrink

----------------------------------------------------------------------------
-- Arbitrary signing keys
----------------------------------------------------------------------------

-- If you want an arbitrary keypair, just generate a secret key with
-- 'arbitrary' and then use 'Pos.Crypto.toPublic' to get the corresponding
-- public key.

keys :: [(PublicKey, SecretKey)]
keys = deterministic "keys" $
    replicateM keysToGenerate keyGen

instance Arbitrary PublicKey where
    arbitrary = fst <$> elements keys
instance Arbitrary SecretKey where
    arbitrary = snd <$> elements keys

instance Nonrepeating PublicKey where
    nonrepeating n = map fst <$> sublistN n keys
instance Nonrepeating SecretKey where
    nonrepeating n = map snd <$> sublistN n keys

instance Arbitrary (NonCached SecretKey) where
    arbitrary =
        NonCached . snd .
        deterministicKeyGen . BS.pack <$> vectorOf 32 arbitrary
instance Arbitrary (NonCached PublicKey) where
    arbitrary = toPublic <<$>> arbitrary

encKeys :: [(PublicKey, EncryptedSecretKey, PassPhrase)]
encKeys =
    deterministic "enc keys" $
    replicateM keysToGenerate $ do
        pp <- getRandomBytes passphraseLength
        let withPass (pk, sk) = (pk, sk, pp)
        withPass <$> safeKeyGen pp

-- perhaps having a datatype with Arbitrary instance would become more
-- convenient here some day
arbitraryEncSecretKey :: Gen (EncryptedSecretKey, PassPhrase)
arbitraryEncSecretKey =
    (\(_, esk, pp) -> (esk, pp)) <$> elements encKeys

-- | Many crypto operations are faster with empty passphrase.
-- This may be useful when test outcome most propably doesn't depend

arbitraryMostlyUnencryptedKeys :: Gen (EncryptedSecretKey, PassPhrase)
arbitraryMostlyUnencryptedKeys = frequency
    [ (1, arbitraryEncSecretKey)
    , (10, arbitrary <&> \sk -> (noPassEncrypt sk, emptyPassphrase))
    ]

-- Repeat the same for ADA redemption keys
redemptionKeys :: [(RedeemPublicKey, RedeemSecretKey)]
redemptionKeys = deterministic "redemptionKeys" $
    replicateM keysToGenerate redeemKeyGen

instance Arbitrary RedeemPublicKey where
    arbitrary = fst <$> elements redemptionKeys
instance Arbitrary RedeemSecretKey where
    arbitrary = snd <$> elements redemptionKeys

instance Nonrepeating RedeemPublicKey where
    nonrepeating n = map fst <$> sublistN n redemptionKeys
instance Nonrepeating RedeemSecretKey where
    nonrepeating n = map snd <$> sublistN n redemptionKeys

----------------------------------------------------------------------------
-- Arbitrary VSS keys
----------------------------------------------------------------------------

vssKeys :: [VssKeyPair]
vssKeys = deterministic "vssKeys" $
    replicateM keysToGenerate vssKeyGen

instance Arbitrary VssKeyPair where
    arbitrary = elements vssKeys

instance Arbitrary VssPublicKey where
    arbitrary = toVssPublicKey <$> arbitrary

instance Arbitrary (AsBinary VssPublicKey) where
    arbitrary = asBinary @VssPublicKey <$> arbitrary

instance Nonrepeating VssKeyPair where
    nonrepeating n = sublistN n vssKeys

instance Nonrepeating VssPublicKey where
    nonrepeating n = map toVssPublicKey <$> nonrepeating n

----------------------------------------------------------------------------
-- Arbitrary signatures
----------------------------------------------------------------------------

instance (HasProtocolConstants, Bi a, Arbitrary a) => Arbitrary (Signature a) where
    arbitrary = sign <$> arbitrary <*> arbitrary <*> arbitrary

instance (HasProtocolConstants, Bi a, Arbitrary a) => Arbitrary (RedeemSignature a) where
    arbitrary = redeemSign <$> arbitrary <*> arbitrary <*> arbitrary

instance (HasProtocolConstants, Bi a, Arbitrary a) => Arbitrary (Signed a) where
    arbitrary = mkSigned <$> arbitrary <*> arbitrary <*> arbitrary

instance (HasProtocolConstants, Bi w, Arbitrary w) => Arbitrary (ProxyCert w) where
    arbitrary = liftA3 createProxyCert arbitrary arbitrary arbitrary

instance (HasProtocolConstants, Bi w, Arbitrary w) => Arbitrary (ProxySecretKey w) where
    arbitrary = liftA3 createPsk arbitrary arbitrary arbitrary

instance (HasProtocolConstants, Bi w, Arbitrary w, Bi a, Arbitrary a) =>
         Arbitrary (ProxySignature w a) where
    arbitrary = do
        delegateSk <- arbitrary
        issuerSk <- arbitrary
        w <- arbitrary
        let psk = createPsk issuerSk (toPublic delegateSk) w
        proxySign SignProxySK delegateSk psk <$> arbitrary

----------------------------------------------------------------------------
-- Arbitrary secrets
----------------------------------------------------------------------------

data SharedSecrets = SharedSecrets
    { ssSecret    :: !Secret
    , ssSecProof  :: !SecretProof
    , ssEncShares :: ![EncShare]
    , ssDecShares :: ![DecShare]
    , ssThreshold :: !Threshold
    , ssVssKeys   :: ![VssPublicKey]
    , ssPos       :: !Int            -- This field is a valid, zero-based index in the
                                     -- shares/keys lists.
    } deriving (Show, Eq)

sharedSecrets :: [SharedSecrets]
sharedSecrets =
    deterministic "sharedSecrets" $ replicateM keysToGenerate $ do
        parties <- randomNumberInRange 4 (toInteger (length vssKeys))
        ssThreshold <- randomNumberInRange 2 (parties - 2)
        vssKs <- sortWith toVssPublicKey <$>
                 sublistN (fromInteger parties) vssKeys
        let ssVssKeys = map toVssPublicKey vssKs
        (ssSecret, ssSecProof, map snd -> ssEncShares) <-
            genSharedSecret ssThreshold (fromList ssVssKeys)
        ssDecShares <- zipWithM decryptShare vssKs ssEncShares
        let ssPos = fromInteger parties - 1
        return SharedSecrets{..}

instance Arbitrary Secret where
    arbitrary = elements . fmap ssSecret $ sharedSecrets

instance Arbitrary (AsBinary Secret) where
    arbitrary = asBinary @Secret <$> arbitrary

instance Arbitrary SecretProof where
    arbitrary = elements . fmap ssSecProof $ sharedSecrets

instance Arbitrary EncShare where
    arbitrary = elements . concatMap ssEncShares $ sharedSecrets

instance Arbitrary (AsBinary EncShare) where
    arbitrary = asBinary @EncShare <$> arbitrary

instance Arbitrary DecShare where
    arbitrary = elements . concatMap ssDecShares $ sharedSecrets

instance Arbitrary (AsBinary DecShare) where
    arbitrary = asBinary @DecShare <$> arbitrary

instance Arbitrary SharedSecrets where
    arbitrary = elements sharedSecrets

----------------------------------------------------------------------------
-- Arbitrary hashes
----------------------------------------------------------------------------

instance (HashAlgorithm algo, Bi a) => Arbitrary (AbstractHash algo a) where
    arbitrary = arbitraryUnsafe

----------------------------------------------------------------------------
-- Arbitrary passphrases
----------------------------------------------------------------------------

instance Arbitrary PassPhrase where
    arbitrary = oneof [
        pure mempty,
        ByteArray.pack <$> vector 32
        ]

----------------------------------------------------------------------------
-- HD
----------------------------------------------------------------------------

instance Arbitrary HDPassphrase where
    arbitrary = HDPassphrase . fromString <$> vector 32

instance Arbitrary HDAddressPayload where
    arbitrary = genericArbitrary
