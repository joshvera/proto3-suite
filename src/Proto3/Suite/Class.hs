-- | This module provides type classes for encoding and decoding protocol
-- buffers message, as well as a safer alternative to the raw 'Proto3.Wire'
-- library based on 'GHC.Generics'.
--
-- = Classes
--
-- The 'Primitive' class captures those types which correspond to primitive field
-- types, as defined by the protocol buffers specification. A 'Primitive' type is
-- one which can always be encoded as a single key/value pair in the wire format.
--
-- The 'MessageField' class captures those types which are encoded under a single
-- key in the wire format, i.e. primitives, packed and unpacked lists, and
-- embedded messages.
--
-- The 'Message' class captures types which correspond to protocol buffers messages.
-- Instances of 'Message' can be written by hand for your types by using the
-- functions in the 'Proto3.Suite.Encode' and 'Proto3.Suite.Decode'
-- modules. In the case where the message format is determined by your Haskell code,
-- you might prefer to derive your 'Message' instances using generic deriving.
--
-- = Generic Instances
--
-- Using the 'GHC.Generics' approach, instead of generating Haskell code from a
-- .proto file, we write our message formats as Haskell types, and generate a
-- serializer/deserializer pair.
--
-- To use this library, simply derive a 'Generic' instance for your type(s), and
-- use the default `Message` instance.
--
-- For generic 'Message' instances, field numbers are automatically generated,
-- starting at 1. Therefore, adding new fields is a compatible change only at the
-- end of a record. Renaming fields is also safe. You should not use the generic
-- instances if you are starting from an existing .proto file.
--
-- = Strings
--
-- Use 'TL.Text' instead of 'String' for string types inside messages.
--
-- = Example
--
-- > data MultipleFields =
-- >   MultipleFields { multiFieldDouble :: Double
-- >                  , multiFieldFloat  :: Float
-- >                  , multiFieldInt32  :: Int32
-- >                  , multiFieldInt64  :: Int64
-- >                  , multiFieldString :: TL.Text
-- >                  , multiFieldBool   :: Bool
-- >                  } deriving (Show, Generic, Eq)
-- >
-- > instance Message MultipleFields
-- >
-- > serialized = toLazyByteString $ MultipleFields 1.0 1.0 1 1 "hi" True
-- >
-- > deserialized :: MultipleFields
-- > deserialized = case parse (toStrict serialized) of
-- >                  Left e -> error e
-- >                  Right msg -> msg

{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE DefaultSignatures          #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE PolyKinds                  #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE TypeOperators              #-}
{-# LANGUAGE UndecidableInstances       #-}

module Proto3.Suite.Class
  ( Primitive(..)
  , MessageField(..)
  , Message(..)
  , Message1(..)

  -- * Encoding
  , toLazyByteString
  , toLazyByteString1

  -- * Decoding
  , HasDefault(..)
  , fromByteString
  , fromByteString1
  , fromB64
  , fromEmbedded''

  -- * Documentation
  , Named1(..)
  , Named(..)
  , Finite(..)
  , message
  , message1
  , Proto3.Suite.Class.enum
  , messageField

  -- * Generic Classes
  , GenericMessage(..)
  , GenericMessage1(..)
  ) where

import Control.Applicative
import           Control.Monad
import qualified Data.ByteString        as B
import qualified Data.ByteString.Base64 as B64
import qualified Data.ByteString.Lazy   as BL
import qualified Data.Foldable          as F
import           Data.Functor           (($>))
import           Data.Int               (Int32, Int64)
import           Data.Maybe             (fromMaybe, isNothing, listToMaybe)
import           Data.Monoid            ((<>))
import           Data.Proxy             (Proxy (..))
import           Data.Sequence          (Seq)
import           Data.String            (IsString (..))
import qualified Data.Text              as T
import qualified Data.Text.Lazy         as TL
import qualified Data.Traversable       as TR
import           Data.Vector            (Vector)
import           Data.Word              (Word32, Word64)
import           GHC.Exts               (fromList)
import           GHC.Generics
import           GHC.TypeLits
import           Proto3.Suite.DotProto  as DotProto
import           Proto3.Suite.Types     as Wire
import           Proto3.Wire
import           Proto3.Wire.Decode     (ParseError, Parser (..), RawField,
                                         RawMessage, RawPrimitive, runParser)
import qualified Proto3.Wire.Decode     as Decode
import qualified Proto3.Wire.Encode     as Encode
import           Safe                   (toEnumMay)
import GHC.TypeLits.Extra
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Debug.Trace (traceShow)
import qualified Data.Char as Char

-- | A class for types with default values per the protocol buffers spec.
class HasDefault a where
  -- | The default value for this type.
  def :: a

  -- | Numeric types default to zero
  default def :: Num a => a
  def = 0

  isDefault :: a -> Bool

  default isDefault :: Eq a => a -> Bool
  isDefault = (== def)

-- | Do not encode the default value
omittingDefault
  :: HasDefault a
  => (a -> Encode.MessageBuilder)
  -> a
  -> Encode.MessageBuilder
omittingDefault f p
  | isDefault p = mempty
  | otherwise = f p

instance HasDefault Int
instance HasDefault Int32
instance HasDefault Int64
instance HasDefault Word32
instance HasDefault Word64
instance HasDefault (Signed Int32)
instance HasDefault (Signed Int64)
instance HasDefault (Fixed Word32)
instance HasDefault (Fixed Word64)
instance HasDefault (Signed (Fixed Int32))
instance HasDefault (Signed (Fixed Int64))
instance HasDefault Float
instance HasDefault Double

instance HasDefault Bool where
  def = False

instance HasDefault String where
  def = mempty

instance HasDefault T.Text where
  def = mempty

instance HasDefault TL.Text where
  def = mempty

instance HasDefault B.ByteString where
  def = mempty

instance HasDefault BL.ByteString where
  def = mempty

instance (Bounded e, Enum e) => HasDefault (Enumerated e) where
  def =
    case toEnumMay 0 of
      Nothing -> Enumerated (Left 0)
      Just x -> Enumerated (Right x)
  isDefault = (== 0) . either id fromEnum . enumerated

instance HasDefault (UnpackedVec a) where
  def = mempty
  isDefault = null . unpackedvec

instance HasDefault (PackedVec a) where
  def = mempty
  isDefault = null . packedvec

instance HasDefault (NestedVec a) where
  def = mempty
  isDefault = null . nestedvec

instance HasDefault (Nested a) where
  def = Nested Nothing
  isDefault = isNothing . nested

instance (HasDefault a) => HasDefault (ForceEmit a) where
  def       = ForceEmit def
  isDefault = isDefault . forceEmit

-- | Used in fields of generated records to represent an unwrapped
-- 'PackedVec'/'UnpackedVec'
instance HasDefault (Vector a) where
  def       = mempty
  isDefault = null

-- | Used in generated records to represent an unwrapped 'Nested'
instance HasDefault (Maybe a) where
  def       = Nothing
  isDefault = isNothing

-- TODO: Determine if we have a reason for rendering fixed32/sfixed as Fixed
-- Word32/Int32 in generated datatypes; for other field types, we omit the
-- newtype wrappers in the type signature but un/wrap them as needed in the
-- encode/decodeMessage implementations. These Fixed wrappers can probably be
-- removed and the type interface would be more consistent with other types, but
-- until that occurs, the following two instances are needed.
--
-- Tracked by https://github.com/awakesecurity/proto3-suite/issues/30.

-- | Used in generated records to represent @sfixed32@
instance HasDefault (Fixed Int32)

-- | Used in generated records to represent @sfixed64@
instance HasDefault (Fixed Int64)

-- | This class captures those types whose names need to appear in .proto files.
--
-- It has a default implementation for any data type which is an instance of the
-- 'Generic' class, which will extract the name of the type constructor.
class Named a where
  -- | Get the name of a type constructor
  nameOf :: IsString string => Proxy a -> string

  default nameOf :: (IsString string, GenericNamed (Rep a)) => Proxy a -> string
  nameOf _ = genericNameOf (Proxy :: Proxy (Rep a))

class Named1 f where
  nameOf1 :: IsString string => Proxy f -> string

  default nameOf1 :: (IsString string, GenericNamed1 (Rep1 f)) => Proxy f -> string
  nameOf1 _ = genericNameOf1 (Proxy :: Proxy (Rep1 f))

class GenericNamed (f :: * -> *) where
  genericNameOf :: IsString string => Proxy f -> string

instance Datatype d => GenericNamed (M1 D d f) where
  genericNameOf _ = fromString (datatypeName (undefined :: M1 D d f ()))

class GenericNamed1 (f :: * -> *) where
  genericNameOf1 :: IsString string => Proxy f -> string

instance Datatype d => GenericNamed1 (M1 D d f) where
  genericNameOf1 _ = fromString (datatypeName (undefined :: M1 D d f ()))

-- | Enumerable types with finitely many values.
--
-- This class can be derived whenever a sum type is an instance of 'Generic',
-- and only consists of zero-argument constructors. The derived instance should
-- be compatible with derived `Enum` instances, in the sense that
--
-- > map (toEnum . fst) enumerate
--
-- should enumerate all values of the type without runtime errors.
class Enum a => Finite a where
  -- | Enumerate values of a finite type, along with names of constructors.
  enumerate :: IsString string => Proxy a -> [(string, Int)]

  default enumerate :: (IsString string, GenericFinite (Rep a)) => Proxy a -> [(string, Int)]
  enumerate _ = snd (genericEnumerate (Proxy @(Rep a)) 0)

-- | Generate metadata for an enum type.
enum :: (Finite e, Named e) => Proxy e -> DotProtoDefinition
enum pr = DotProtoEnum (Single $ nameOf pr) (map enumField $ enumerate pr)
  where
    enumField (name, value) = DotProtoEnumField (Single name) value []

class GenericFinite (f :: * -> *) where
  genericEnumerate :: IsString string => Proxy f -> Int -> (Int, [(string, Int)])

instance ( GenericFinite f
         , GenericFinite g
         ) => GenericFinite (f :+: g) where
  genericEnumerate _ i =
    let (j, e1) = genericEnumerate (Proxy @f) i
        (k, e2) = genericEnumerate (Proxy @g) j
    in (k, e1 <> e2)

instance Constructor c => GenericFinite (M1 C c f) where
  genericEnumerate _ i = (i + 1, [ (fromString name, i) ])
    where
      name = conName (undefined :: M1 C c f ())

instance GenericFinite f => GenericFinite (M1 D t f) where
  genericEnumerate _ = genericEnumerate (Proxy @f)

instance GenericFinite f => GenericFinite (M1 S t f) where
  genericEnumerate _ = genericEnumerate (Proxy @f)

-- | This class captures those types which correspond to primitives in
-- the protocol buffers specification.
--
-- It should be possible to fully reconstruct values of these types from
-- a single 'RawPrimitive'. Notably, then, `Nested` is not `Primitive` even
-- though it can be 'embedded', since a nested message may by split up over
-- multiple 'embedded' fields.
class Primitive a where
  -- | Encode a primitive value
  encodePrimitive :: FieldNumber -> a -> Encode.MessageBuilder
  -- | Decode a primitive value
  decodePrimitive :: Parser RawPrimitive a
  -- | Get the type which represents this type inside another message.
  primType :: Proxy a -> DotProtoPrimType

  default primType :: Named a => Proxy a -> DotProtoPrimType
  primType pr = Named (Single (nameOf pr))

-- | Serialize a message as a lazy 'BL.ByteString'.
toLazyByteString :: Message a => a -> BL.ByteString
toLazyByteString = Encode.toLazyByteString . encodeMessage (fieldNumber 1)

-- | Decode any embedded message.
fromEmbedded'' :: Parser RawMessage a -> FieldNumber -> Parser RawMessage a
fromEmbedded'' parser = Decode.at (Decode.embedded'' parser)

-- | Parse any message that can be decoded.
fromByteString :: Message a => B.ByteString -> Either ParseError a
fromByteString = Decode.parse (decodeMessage (fieldNumber 1))

fromByteString1 :: (Message1 f, Message a) => B.ByteString -> Either ParseError (f a)
fromByteString1 = Decode.parse (liftDecodeMessage decodeMessage (fieldNumber 1))

toLazyByteString1 :: (Message1 f, Message a) => f a -> BL.ByteString
toLazyByteString1 = Encode.toLazyByteString . liftEncodeMessage encodeMessage (fieldNumber 1)

-- | As 'fromByteString', except the input bytestring is base64-encoded.
fromB64 :: Message a => B.ByteString -> Either ParseError a
fromB64 = fromByteString . B64.decodeLenient

instance Primitive Int where
  encodePrimitive = Encode.int
  decodePrimitive = Decode.int
  primType _ = Int64

instance Primitive Int32 where
  encodePrimitive = Encode.int32
  decodePrimitive = Decode.int32
  primType _ = Int32

instance Primitive Int64 where
  encodePrimitive = Encode.int64
  decodePrimitive = Decode.int64
  primType _ = Int64

instance Primitive Word32 where
  encodePrimitive = Encode.uint32
  decodePrimitive = Decode.uint32
  primType _ = UInt32

instance Primitive Word64 where
  encodePrimitive = Encode.uint64
  decodePrimitive = Decode.uint64
  primType _ = UInt64

instance Primitive (Signed Int32) where
  encodePrimitive num = Encode.sint32 num . signed
  decodePrimitive = fmap Signed Decode.sint32
  primType _ = SInt32

instance Primitive (Signed Int64) where
  encodePrimitive num = Encode.sint64 num . signed
  decodePrimitive = fmap Signed Decode.sint64
  primType _ = SInt64

instance Primitive (Fixed Word32) where
  encodePrimitive num = Encode.fixed32 num . fixed
  decodePrimitive = fmap Fixed Decode.fixed32
  primType _ = DotProto.Fixed32

instance Primitive (Fixed Word64) where
  encodePrimitive num = Encode.fixed64 num . fixed
  decodePrimitive = fmap Fixed Decode.fixed64
  primType _ = DotProto.Fixed64

instance Primitive (Signed (Fixed Int32)) where
  encodePrimitive num = Encode.sfixed32 num . fixed . signed
  decodePrimitive = fmap (Signed . Fixed) Decode.sfixed32
  primType _ = SFixed32

instance Primitive (Signed (Fixed Int64)) where
  encodePrimitive num = Encode.sfixed64 num . fixed . signed
  decodePrimitive = fmap (Signed . Fixed) Decode.sfixed64
  primType _ = SFixed64

instance Primitive Bool where
  encodePrimitive = Encode.enum
  decodePrimitive = Decode.bool
  primType _ = Bool

instance Primitive Float where
  encodePrimitive = Encode.float
  decodePrimitive = Decode.float
  primType _ = Float

instance Primitive Double where
  encodePrimitive = Encode.double
  decodePrimitive = Decode.double
  primType _ = Double

instance Primitive T.Text where
  encodePrimitive fn = Encode.text fn . TL.fromStrict
  decodePrimitive = fmap TL.toStrict Decode.text
  primType _ = String

instance Primitive TL.Text where
  encodePrimitive = Encode.text
  decodePrimitive = Decode.text
  primType _ = String

instance Primitive B.ByteString where
  encodePrimitive = Encode.byteString
  decodePrimitive = Decode.byteString
  primType _ = Bytes

instance Primitive String where
  encodePrimitive num = Encode.text num . TL.pack
  decodePrimitive = fmap TL.unpack Decode.text
  primType _ = String

instance Primitive BL.ByteString where
  encodePrimitive = Encode.lazyByteString
  decodePrimitive = Decode.lazyByteString
  primType _ = Bytes

instance forall e. (Bounded e, Named e, Enum e) => Primitive (Enumerated e) where
  encodePrimitive num = Encode.enum num . enumify . enumerated
    where enumify (Left i) = i
          enumify (Right x) = fromEnum x
  decodePrimitive = fmap Enumerated Decode.enum
  primType _ = Named (Single (nameOf (Proxy @e)))

instance (Primitive a) => Primitive (ForceEmit a) where
  encodePrimitive num = encodePrimitive num . forceEmit
  decodePrimitive     = fmap ForceEmit decodePrimitive
  primType _          = primType (Proxy @a)

instance MessageField1 f => GenericMessage1 (Rec1 f) where
  type GenericFieldCount1 (Rec1 f) = 1
  genericLiftEncodeMessage encodeMessage fieldNumber (Rec1 x) = liftEncodeMessageField encodeMessage fieldNumber x
  genericLiftDecodeMessage decodeMessage fieldNumber = fmap Rec1 $ at (liftDecodeMessageField decodeMessage) fieldNumber
  genericLiftDotProto (_ :: Proxy (Rec1 f a)) = [ DotProtoMessageField $ liftProtoType (Proxy @(f a)) ]

instance GenericMessage1 Par1 where
  type GenericFieldCount1 Par1 = 1
  genericLiftEncodeMessage encodeMessage fieldNumber (Par1 x) = Encode.embedded fieldNumber (encodeMessage 1 x)
  genericLiftDecodeMessage decodeMessage fieldNumber = Par1 . fromMaybe undefined <$> Decode.at (Decode.embedded (decodeMessage 1)) fieldNumber
  genericLiftDotProto (_ :: Proxy (Par1 a)) = [ DotProtoMessageField $ messageField (Prim (Named (Single (nameOf (Proxy @a))))) Nothing ]


class MessageField1 f where
  liftEncodeMessageField :: (FieldNumber -> a -> Encode.MessageBuilder) -> FieldNumber -> f a -> Encode.MessageBuilder
  -- | Decode a message field
  liftDecodeMessageField :: (FieldNumber -> Parser RawMessage a) -> Parser RawField (f a)
  liftProtoType :: Named a => Proxy (f a) -> DotProtoField

instance MessageField1 [] where
  liftEncodeMessageField encodeMessage fn = foldMap (Encode.embedded fn . encodeMessage (fieldNumber 1))
  liftDecodeMessageField decodeMessage = fmap F.toList (repeated (Decode.embedded' oneMsg))
    where
      oneMsg = decodeMessage (fieldNumber 1)
  liftProtoType (_ :: Proxy [a]) = messageField (NestedRepeated (Named (Single (nameOf (Proxy @a))))) Nothing

instance MessageField1 NonEmpty where
  liftEncodeMessageField encodeMessage fn = foldMap (Encode.embedded fn . encodeMessage (fieldNumber 1))
  liftDecodeMessageField decodeMessage = fmap (NonEmpty.fromList . F.toList) (repeated (Decode.embedded' oneMsg))
    where
      oneMsg = decodeMessage (fieldNumber 1)
  liftProtoType (_ :: Proxy (NonEmpty a)) = messageField (NestedRepeated (Named (Single (nameOf (Proxy @a))))) Nothing

instance MessageField1 Maybe where
  liftEncodeMessageField encodeMessage fn = foldMap (Encode.embedded fn . encodeMessage (fieldNumber 1))
  liftDecodeMessageField decodeMessage = fmap (listToMaybe . F.toList) (repeated (Decode.embedded' oneMsg))
    where
      oneMsg = decodeMessage (fieldNumber 1)
  liftProtoType (_ :: Proxy (Maybe a)) = messageField (NestedRepeated (Named (Single (nameOf (Proxy @a))))) Nothing

-- | This class captures those types which can appear as message fields in
-- the protocol buffers specification, i.e. 'Primitive' types, or lists of
-- 'Primitive' types
class MessageField a where
  -- | Encode a message field
  encodeMessageField :: FieldNumber -> a -> Encode.MessageBuilder
  -- | Decode a message field
  decodeMessageField :: Parser RawField a

  default encodeMessageField :: (HasDefault a, Primitive a) => FieldNumber -> a -> Encode.MessageBuilder
  encodeMessageField num x
    | isDefault x = mempty
    | otherwise = encodePrimitive num x

  default decodeMessageField :: (HasDefault a, Primitive a) => Parser RawField a
  decodeMessageField = one decodePrimitive def

  -- | Get the type which represents this type inside another message.
  protoType :: Proxy a -> DotProtoField
  default protoType :: Primitive a => Proxy a -> DotProtoField
  protoType p = messageField (Prim $ primType p) Nothing

messageField :: DotProtoType -> Maybe DotProto.Packing -> DotProtoField
messageField ty packing = DotProtoField (fieldNumber 1) ty Anonymous
                            (case packing of
                              (Just DotProto.PackedField)   -> [DotProtoOption (Single "packed") (BoolLit True)]
                              (Just DotProto.UnpackedField) -> [DotProtoOption (Single "packed") (BoolLit False)]
                              Nothing -> [])
                            Nothing
-- [todo] what were these intended for?
-- primDotProto :: DotProtoMessagePart -> DotProtoDefinition
-- primDotProto field = DotProtoMessage generateMessagePartName [ field ]

-- generateMessagePartName :: DotProtoIdentifier
-- generateMessagePartName = Single ""

instance MessageField Int
instance MessageField Int32
instance MessageField Int64
instance MessageField Word32
instance MessageField Word64
instance MessageField (Signed Int32)
instance MessageField (Signed Int64)
instance MessageField (Fixed Word32)
instance MessageField (Fixed Word64)
instance MessageField (Signed (Fixed Int32))
instance MessageField (Signed (Fixed Int64))
instance MessageField Bool
instance MessageField Float
instance MessageField Double
instance {-# OVERLAPPING #-} MessageField String
instance MessageField T.Text
instance MessageField TL.Text
instance MessageField B.ByteString
instance MessageField BL.ByteString
instance (Bounded e, Named e, Enum e) => MessageField (Enumerated e)

instance (HasDefault a, Primitive a) => MessageField (ForceEmit a) where
  encodeMessageField = encodePrimitive

seqToVec :: Seq a -> Vector a
seqToVec = fromList . F.toList

instance (Named a, Message a) => MessageField (Maybe a) where
  encodeMessageField num = foldMap (Encode.embedded num . encodeMessage (fieldNumber 1))
  decodeMessageField = (Decode.embedded (decodeMessage (fieldNumber 1)))
  protoType _ = messageField (Prim $ Named (Single (nameOf (Proxy @a)))) Nothing

instance (Named a, Message a) => MessageField (Nested a) where
  encodeMessageField num = foldMap (Encode.embedded num . encodeMessage (fieldNumber 1)) . nested
  decodeMessageField = fmap Nested (Decode.embedded (decodeMessage (fieldNumber 1)))
  protoType _ = messageField (Prim $ Named (Single (nameOf (Proxy @a)))) Nothing

instance Primitive a => MessageField (UnpackedVec a) where
  encodeMessageField fn = foldMap (encodePrimitive fn)
  decodeMessageField = fmap (UnpackedVec . seqToVec) $ repeated decodePrimitive
  protoType _ = messageField (Repeated $ primType (Proxy @a)) (Just DotProto.UnpackedField)

instance (Named a, Message a) => MessageField (NestedVec a) where
  encodeMessageField fn = foldMap (Encode.embedded fn . encodeMessage (fieldNumber 1))
                          . nestedvec
  decodeMessageField = fmap (NestedVec . seqToVec)
                            (repeated (Decode.embedded' oneMsg))
    where
      oneMsg :: Parser RawMessage a
      oneMsg = decodeMessage (fieldNumber 1)
  protoType _ = messageField (NestedRepeated (Named (Single (nameOf (Proxy @a))))) Nothing

instance {-# OVERLAPPABLE #-} (Named a, Message a) => MessageField [a] where
  encodeMessageField fn = foldMap (Encode.embedded fn . encodeMessage (fieldNumber 1))
  decodeMessageField = fmap F.toList (repeated (Decode.embedded' oneMsg))
    where
      oneMsg :: Parser RawMessage a
      oneMsg = decodeMessage (fieldNumber 1)
  protoType _ = messageField (NestedRepeated (Named (Single (nameOf (Proxy @a))))) Nothing

instance (Named a, Message a, HasDefault a) => MessageField (NonEmpty a) where
  encodeMessageField fn = foldMap (Encode.embedded fn . encodeMessage (fieldNumber 1))
  decodeMessageField = fmap (fromMaybe (pure def) . NonEmpty.nonEmpty . F.toList) (repeated (Decode.embedded' oneMsg))
    where
      oneMsg :: Parser RawMessage a
      oneMsg = decodeMessage (fieldNumber 1)
  protoType _ = messageField (NestedRepeated (Named (Single (nameOf (Proxy @a))))) Nothing

instance (Bounded e, Enum e, Named e) => MessageField (PackedVec (Enumerated e)) where
  encodeMessageField fn = omittingDefault (Encode.packedVarints fn) . foldMap omit
    where
      -- omit values which are outside the enum range
      omit :: Enumerated e -> PackedVec Word64
      omit (Enumerated (Right e)) = pure . fromIntegral . fromEnum $ e
      omit _                      = mempty
  decodeMessageField = decodePacked (foldMap retain <$> Decode.packedVarints @Word64)
    where
      -- retain only those values which are inside the enum range
      retain = foldMap (pure . Enumerated. Right) . toEnumMay . fromIntegral
  protoType _ = messageField (Repeated (Named (Single (nameOf (Proxy @e))))) (Just DotProto.PackedField)

instance MessageField (PackedVec Bool) where
  encodeMessageField fn = omittingDefault (Encode.packedVarints fn) . fmap fromBool
    where
      fromBool False = 0
      fromBool True  = 1
  decodeMessageField = fmap (fmap toBool) (decodePacked Decode.packedVarints)
    where
      toBool :: Word64 -> Bool
      toBool 1 = True
      toBool _ = False
  protoType _ = messageField (Repeated Bool) (Just DotProto.PackedField)

instance MessageField (PackedVec Word32) where
  encodeMessageField fn = omittingDefault (Encode.packedVarints fn) . fmap fromIntegral
  decodeMessageField = decodePacked Decode.packedVarints
  protoType _ = messageField (Repeated UInt32) (Just DotProto.PackedField)

instance MessageField (PackedVec Word64) where
  encodeMessageField fn = omittingDefault (Encode.packedVarints fn) . fmap fromIntegral
  decodeMessageField = decodePacked Decode.packedVarints
  protoType _ = messageField (Repeated UInt64) (Just DotProto.PackedField)

instance MessageField (PackedVec Int32) where
  encodeMessageField fn = omittingDefault (Encode.packedVarints fn) . fmap fromIntegral
  decodeMessageField = decodePacked Decode.packedVarints
  protoType _ = messageField (Repeated Int32) (Just DotProto.PackedField)

instance MessageField (PackedVec Int64) where
  encodeMessageField fn = omittingDefault (Encode.packedVarints fn) . fmap fromIntegral
  decodeMessageField = decodePacked Decode.packedVarints
  protoType _ = messageField (Repeated Int64) (Just DotProto.PackedField)

instance MessageField (PackedVec (Fixed Word32)) where
  encodeMessageField fn = omittingDefault (Encode.packedFixed32 fn) . fmap fixed
  decodeMessageField = fmap (fmap Fixed) (decodePacked Decode.packedFixed32)
  protoType _ = messageField (Repeated DotProto.Fixed32) (Just DotProto.PackedField)

instance MessageField (PackedVec (Fixed Word64)) where
  encodeMessageField fn = omittingDefault (Encode.packedFixed64 fn) . fmap fixed
  decodeMessageField = fmap (fmap Fixed) (decodePacked Decode.packedFixed64)
  protoType _ = messageField (Repeated DotProto.Fixed64) (Just DotProto.PackedField)

instance MessageField (PackedVec (Signed (Fixed Int32))) where
  encodeMessageField fn = omittingDefault (Encode.packedFixed32 fn) . fmap (fromIntegral . fixed . signed)
  decodeMessageField = fmap (fmap (Signed . Fixed)) (decodePacked Decode.packedFixed32)
  protoType _ = messageField (Repeated SFixed32) (Just DotProto.PackedField)

instance MessageField (PackedVec (Signed (Fixed Int64))) where
  encodeMessageField fn = omittingDefault (Encode.packedFixed64 fn) . fmap (fromIntegral . fixed . signed)
  decodeMessageField = fmap (fmap (Signed . Fixed)) (decodePacked Decode.packedFixed64)
  protoType _ = messageField (Repeated SFixed64) (Just DotProto.PackedField)

instance MessageField (PackedVec Float) where
  encodeMessageField fn = omittingDefault (Encode.packedFloats fn)
  decodeMessageField = decodePacked Decode.packedFloats
  protoType _ = messageField (Repeated Float) (Just DotProto.PackedField)

instance MessageField (PackedVec Double) where
  encodeMessageField fn = omittingDefault (Encode.packedDoubles fn)
  decodeMessageField = decodePacked Decode.packedDoubles
  protoType _ = messageField (Repeated Double) (Just DotProto.PackedField)

instance (MessageField e, KnownSymbol comments) => MessageField (e // comments) where
  encodeMessageField fn = encodeMessageField fn . unCommented
  decodeMessageField = fmap Commented decodeMessageField
  protoType p = (protoType (lowerProxy1 p))
                  { dotProtoFieldComment = Just (symbolVal (lowerProxy2 p)) }
    where
      lowerProxy1 :: forall f (a :: k). Proxy (f a) -> Proxy a
      lowerProxy1 _ = Proxy

      lowerProxy2 :: forall f (a :: k) b. Proxy (f a b) -> Proxy a
      lowerProxy2 _ = Proxy

decodePacked
  :: Parser RawPrimitive [a]
  -> Parser RawField (PackedVec a)
decodePacked p = Parser $ \fs -> fmap (fromList . join . F.toList) $ TR.sequence $ fmap (runParser p) fs

-- | This class captures those types which correspond to protocol buffer messages.
class Message a where
  -- | Encode a message
  encodeMessage :: FieldNumber -> a -> Encode.MessageBuilder
  -- | Decode a message
  decodeMessage :: FieldNumber -> Parser RawMessage a
  -- | Generate a .proto message from the type information.
  dotProto :: Proxy a -> [DotProtoMessagePart]

  default encodeMessage :: (Generic a, GenericMessage (Rep a)) => FieldNumber -> a -> Encode.MessageBuilder
  encodeMessage num = genericEncodeMessage num . from

  default decodeMessage :: (Generic a, GenericMessage (Rep a)) => FieldNumber -> Parser RawMessage a
  decodeMessage = (fmap to .) genericDecodeMessage

  default dotProto :: GenericMessage (Rep a) => Proxy a -> [DotProtoMessagePart]
  dotProto _ = genericDotProto (Proxy @(Rep a))

class Message1 f where
  liftEncodeMessage :: (FieldNumber -> a -> Encode.MessageBuilder) -> FieldNumber -> f a -> Encode.MessageBuilder
  default liftEncodeMessage :: (Generic1 f, GenericMessage1 (Rep1 f)) => (FieldNumber -> a -> Encode.MessageBuilder) -> FieldNumber -> f a -> Encode.MessageBuilder
  liftEncodeMessage encodeMessage fieldNumber = genericLiftEncodeMessage encodeMessage fieldNumber . from1

  liftDecodeMessage :: (FieldNumber -> Parser RawMessage a) -> FieldNumber -> Parser RawMessage (f a)
  default liftDecodeMessage :: (Generic1 f, GenericMessage1 (Rep1 f)) => (FieldNumber -> Parser RawMessage a) -> FieldNumber -> Parser RawMessage (f a)
  liftDecodeMessage decodeMessage fieldNumber = fmap to1 $ genericLiftDecodeMessage decodeMessage fieldNumber

  liftDotProto :: Named a => Proxy (f a) -> [DotProtoMessagePart]
  default liftDotProto :: (Named a, GenericMessage1 (Rep1 f)) => Proxy (f a) -> [DotProtoMessagePart]
  liftDotProto (_ :: Proxy (f a)) = genericLiftDotProto (Proxy @(Rep1 f a))

-- | Generate metadata for a message type.
message :: (Message a, Named a) => Proxy a -> DotProtoDefinition
message pr = DotProtoMessage (Single $ nameOf pr) (dotProto pr)

message1 :: (Named1 f, Named a, Message1 f, Message a) => Proxy (f a) -> DotProtoDefinition
message1 (pr :: Proxy (f a)) = DotProtoMessage (Single $ nameOf1 (Proxy @f)) (liftDotProto pr)

-- * Generic Instances

class GenericMessage1 (f :: * -> *) where
  type GenericFieldCount1 f :: Nat
  genericLiftEncodeMessage :: (FieldNumber -> a -> Encode.MessageBuilder) -> FieldNumber -> f a -> Encode.MessageBuilder
  genericLiftDecodeMessage :: (FieldNumber -> Parser RawMessage a) -> FieldNumber -> Parser RawMessage (f a)
  genericLiftDotProto :: Named a => Proxy (f a) -> [DotProtoMessagePart]

instance GenericMessage1 U1 where
  type GenericFieldCount1 U1 = 0
  genericLiftEncodeMessage _ num _ = mempty
  genericLiftDecodeMessage _ num = pure U1
  genericLiftDotProto _      = mempty

-- TODO Maybe the field number with encode.embedded and decode.embedded
instance GenericMessage1 f => GenericMessage1 (M1 D c f) where
  type GenericFieldCount1 (M1 D c f) = GenericFieldCount1 f
  genericLiftEncodeMessage encodeMessage fieldNumber (M1 x) = genericLiftEncodeMessage encodeMessage fieldNumber x
  genericLiftDecodeMessage decodeMessage fieldNumber = fmap M1 $ genericLiftDecodeMessage decodeMessage fieldNumber
  genericLiftDotProto (_ :: Proxy (M1 D c f a)) = genericLiftDotProto (Proxy @(f a))

instance (GenericMessage1 f) => GenericMessage1 (M1 C c f) where
  type GenericFieldCount1 (M1 C c f) = GenericFieldCount1 f
  genericLiftEncodeMessage encodeMessage fieldNumber (M1 x) = genericLiftEncodeMessage encodeMessage fieldNumber x
  genericLiftDecodeMessage decodeMessage fieldNumber = fmap M1 $ genericLiftDecodeMessage decodeMessage fieldNumber
  genericLiftDotProto (_ :: Proxy (M1 C c f a)) = genericLiftDotProto (Proxy @(f a))

instance (Selector s, GenericMessage1 f) => GenericMessage1 (M1 S s f) where
  type GenericFieldCount1 (M1 S s f) = GenericFieldCount1 f
  genericLiftEncodeMessage encodeMessage fieldNumber (M1 x) = genericLiftEncodeMessage encodeMessage fieldNumber x
  genericLiftDecodeMessage decodeMessage fieldNumber = fmap M1 $ genericLiftDecodeMessage decodeMessage fieldNumber
  genericLiftDotProto (_ :: Proxy (M1 S s f a)) = map applyName $ genericLiftDotProto (Proxy @(f a))
    where
      applyName :: DotProtoMessagePart -> DotProtoMessagePart
      applyName (DotProtoMessageField mp) = DotProtoMessageField $ mp { dotProtoFieldName = fromMaybe Anonymous newName} -- [issue] this probably doesn't match the intended name generating semantics
      applyName part = part -- Don't modify other types of message parts?

      newName :: Maybe DotProtoIdentifier
      newName = guard (not (null name)) $> Single name
        where
          name = selName (undefined :: S1 s f ())

instance (KnownNat (GenericFieldCount1 f), GenericMessage1 f, GenericMessage1 g) => GenericMessage1 (f :+: g) where
  type GenericFieldCount1 (f :+: g) = GenericFieldCount1 f + GenericFieldCount1 g
  genericLiftEncodeMessage encodeMessage num (L1 l) = genericLiftEncodeMessage encodeMessage num l
  genericLiftEncodeMessage encodeMessage num (R1 r) = genericLiftEncodeMessage encodeMessage num r
  -- FIXME: Implement these
  genericLiftDecodeMessage decodeMessage num = L1 <$> genericLiftDecodeMessage decodeMessage num <|> R1 <$> genericLiftDecodeMessage decodeMessage num
  genericLiftDotProto (_ :: Proxy ((f :+: g) a)) = sumProtos (genericLiftDotProto (Proxy @(f a))) (adjust (genericLiftDotProto (Proxy @(g a))))
    where
      sumProtos [(DotProtoMessageField leftField)] [(DotProtoMessageField rightField)] = pure $ DotProtoMessageOneOf (Single "sum") [ leftField, rightField ]
      sumProtos [(DotProtoMessageOneOf name fields)] [(DotProtoMessageField rightField)] = pure $ DotProtoMessageOneOf name (fields <> [ rightField ])
      sumProtos [(DotProtoMessageField leftField)] [(DotProtoMessageOneOf name fields)] = pure $ DotProtoMessageOneOf name (leftField : fields)
      sumProtos [(DotProtoMessageOneOf name fields)] [(DotProtoMessageOneOf name' rightFields)] = pure $ DotProtoMessageOneOf name (fields <> rightFields)
      sumProtos messages others = messages <> others
      offset = fromIntegral $ natVal (Proxy @(GenericFieldCount1 f))
      adjust = map adjustPart
      adjustPart (DotProtoMessageField part) =
        DotProtoMessageField part { dotProtoFieldNumber = (FieldNumber . (offset +) . getFieldNumber . dotProtoFieldNumber) part }
      adjustPart part = part -- Don't adjust other message types?


instance (KnownNat (GenericFieldCount1 f), GenericMessage1 f, GenericMessage1 g) => GenericMessage1 (f :*: g) where
  type GenericFieldCount1 (f :*: g) = GenericFieldCount1 f + GenericFieldCount1 g
  genericLiftEncodeMessage encodeMessage num (x :*: y) = genericLiftEncodeMessage encodeMessage num x <> genericLiftEncodeMessage encodeMessage (FieldNumber (getFieldNumber num + offset)) y
    where
      offset = fromIntegral $ natVal (Proxy @(GenericFieldCount1 f))
  genericLiftDecodeMessage decodeMessage num = liftM2 (:*:) (genericLiftDecodeMessage decodeMessage num) (genericLiftDecodeMessage decodeMessage num2)
    where num2 = FieldNumber $ getFieldNumber num + offset
          offset = fromIntegral $ natVal (Proxy @(GenericFieldCount1 f))
  genericLiftDotProto (_ :: Proxy ((f :*: g) a)) = genericLiftDotProto (Proxy @(f a)) <> adjust (genericLiftDotProto (Proxy @(g a)))
    where
      offset = fromIntegral $ natVal (Proxy @(GenericFieldCount1 f))
      adjust = map adjustPart
      adjustPart (DotProtoMessageField part) =
        DotProtoMessageField part { dotProtoFieldNumber = (FieldNumber . (offset +) . getFieldNumber . dotProtoFieldNumber) part }
      adjustPart part = part -- Don't adjust other message types?

instance MessageField c => GenericMessage1 (K1 i c) where
  type GenericFieldCount1 (K1 i c) = 1
  genericLiftEncodeMessage _ num (K1 x) = encodeMessageField num x
  genericLiftDecodeMessage _ num = K1 <$> decodeMessageField `at` num
  genericLiftDotProto _ = [ DotProtoMessageField $ protoType (Proxy @c) ]

class GenericMessage (f :: * -> *) where
  type GenericFieldCount f :: Nat

  genericEncodeMessage :: FieldNumber -> f a -> Encode.MessageBuilder
  genericDecodeMessage :: FieldNumber -> Parser RawMessage (f a)
  genericDotProto      :: Proxy f -> [DotProtoMessagePart]

instance GenericMessage U1 where
  type GenericFieldCount U1 = 0
  genericEncodeMessage _ = mempty
  genericDecodeMessage _ = return U1
  genericDotProto _      = mempty

instance (KnownNat (GenericFieldCount f), GenericMessage f, GenericMessage g) => GenericMessage (f :*: g) where
  type GenericFieldCount (f :*: g) = GenericFieldCount f + GenericFieldCount g
  genericEncodeMessage num (x :*: y) = genericEncodeMessage num x <> genericEncodeMessage (FieldNumber (getFieldNumber num + offset)) y
    where
      offset = fromIntegral $ natVal (Proxy @(GenericFieldCount f))
  genericDecodeMessage num = liftM2 (:*:) (genericDecodeMessage num) (genericDecodeMessage num2)
    where num2 = FieldNumber $ getFieldNumber num + offset
          offset = fromIntegral $ natVal (Proxy @(GenericFieldCount f))
  genericDotProto _ = genericDotProto (Proxy @f) <> adjust (genericDotProto (Proxy @g))
    where
      offset = fromIntegral $ natVal (Proxy @(GenericFieldCount f))
      adjust = map adjustPart
      adjustPart (DotProtoMessageField part) =
        DotProtoMessageField part { dotProtoFieldNumber = (FieldNumber . (offset +) . getFieldNumber . dotProtoFieldNumber) part }
      adjustPart part = part -- Don't adjust other message types?

instance (Constructor t1, Constructor t2, GenericMessage f, GenericMessage g) => GenericMessage (M1 C t1 f :+: M1 C t2 g) where
  type GenericFieldCount (C1 t1 f :+: C1 t2 g) = GenericFieldCount f `Max` GenericFieldCount g
  genericEncodeMessage num (L1 x) = genericEncodeMessage num x
  genericEncodeMessage num (R1 y) = genericEncodeMessage num y
  genericDecodeMessage num = L1 <$> genericDecodeMessage num <|> R1 <$> genericDecodeMessage num
  genericDotProto (_ :: Proxy (M1 C t1 f :+: M1 C t2 g)) = sumProtos (genericDotProto (Proxy @f)) (genericDotProto (Proxy @g))
    where
      sumProtos fields1 fields2 =
        [ DotProtoMessageOneOf (Single "sum")
            [ DotProtoField 1 (Prim (Named (Single (conName (undefined :: C1 t1 f ()))))) (Single (toLower $ conName (undefined :: C1 t1 f ()))) [] Nothing
            , DotProtoField 2 (Prim (Named (Single (conName (undefined :: C1 t2 g ()))))) (Single (toLower $ conName (undefined :: C1 t2 g ()))) [] Nothing ]
        , DotProtoMessageDefinition $ DotProtoMessage (Single (conName (undefined :: C1 t1 f ()))) fields1
        , DotProtoMessageDefinition $ DotProtoMessage (Single (conName (undefined :: C1 t2 g ()))) fields2
        ]
        where
          toLower (x : xs) = Char.toLower x : xs

instance MessageField c => GenericMessage (K1 i c) where
  type GenericFieldCount (K1 i c) = 1
  genericEncodeMessage num (K1 x) = encodeMessageField num x
  genericDecodeMessage num = fmap K1 (at decodeMessageField num)
  genericDotProto _ = [DotProtoMessageField $ protoType (Proxy @c)]

instance (Selector s, GenericMessage f) => GenericMessage (M1 S s f) where
  type GenericFieldCount (M1 S s f) = GenericFieldCount f
  genericEncodeMessage num (M1 x) = genericEncodeMessage num x
  genericDecodeMessage num = fmap M1 $ genericDecodeMessage num
  genericDotProto _ = map applyName $ genericDotProto (Proxy @f)
    where
      applyName :: DotProtoMessagePart -> DotProtoMessagePart
      applyName (DotProtoMessageField mp) = DotProtoMessageField $ mp { dotProtoFieldName = fromMaybe Anonymous newName} -- [issue] this probably doesn't match the intended name generating semantics
      applyName part = part

      newName :: Maybe DotProtoIdentifier
      newName = guard (not (null name)) $> Single name
        where
          name = selName (undefined :: S1 s f ())

instance GenericMessage f => GenericMessage (M1 C t f) where
  type GenericFieldCount (M1 C t f) = GenericFieldCount f
  genericEncodeMessage num (M1 x) = genericEncodeMessage num x
  genericDecodeMessage num = fmap M1 $ genericDecodeMessage num
  genericDotProto _ = genericDotProto (Proxy @f)

instance GenericMessage f => GenericMessage (M1 D t f) where
  type GenericFieldCount (M1 D t f) = GenericFieldCount f
  genericEncodeMessage num (M1 x) = Encode.embedded num (genericEncodeMessage 1 x)
  genericDecodeMessage num = fmap M1 $ Decode.at (Decode.embedded'' (genericDecodeMessage 1)) num
  genericDotProto _ = genericDotProto (Proxy @f)
