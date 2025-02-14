{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ViewPatterns #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Database.Beam.AutoMigrate.Postgres
  ( getSchema,
  )
where

import Control.Monad.State
import Data.Bits (shiftR, (.&.))
import Data.ByteString (ByteString)
import Data.Foldable (asum, foldlM)
import Data.Map (Map)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import qualified Data.Set as S
import Data.String
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Vector as V
import Database.Beam.AutoMigrate.Types
import Database.Beam.Backend.SQL hiding (tableName)
import qualified Database.Beam.Backend.SQL.AST as AST
import qualified Database.PostgreSQL.Simple as Pg
import Database.PostgreSQL.Simple.FromField (FromField (..), fromField, returnError)
import Database.PostgreSQL.Simple.FromRow (FromRow (..), field)
import qualified Database.PostgreSQL.Simple.TypeInfo.Static as Pg
import qualified Database.PostgreSQL.Simple.Types as Pg

--
-- Necessary types to make working with the underlying raw SQL a bit more pleasant
--

data SqlRawOtherConstraintType
  = SQL_raw_pk
  | SQL_raw_unique
  deriving (Show, Eq)

data SqlOtherConstraint = SqlOtherConstraint
  { sqlCon_name :: Text,
    sqlCon_constraint_type :: SqlRawOtherConstraintType,
    sqlCon_table :: TableName,
    sqlCon_fk_colums :: V.Vector ColumnName
  }
  deriving (Show, Eq)

instance Pg.FromRow SqlOtherConstraint where
  fromRow =
    SqlOtherConstraint <$> field
      <*> field
      <*> fmap TableName field
      <*> fmap (V.map ColumnName) field

data SqlForeignConstraint = SqlForeignConstraint
  { sqlFk_foreign_table :: TableName,
    sqlFk_primary_table :: TableName,
    -- | The columns in the /foreign/ table.
    sqlFk_fk_columns :: V.Vector ColumnName,
    -- | The columns in the /current/ table.
    sqlFk_pk_columns :: V.Vector ColumnName,
    sqlFk_name :: Text
  }
  deriving (Show, Eq)

instance Pg.FromRow SqlForeignConstraint where
  fromRow =
    SqlForeignConstraint <$> fmap TableName field
      <*> fmap TableName field
      <*> fmap (V.map ColumnName) field
      <*> fmap (V.map ColumnName) field
      <*> field

instance FromField TableName where
  fromField f dat = TableName <$> fromField f dat

instance FromField ColumnName where
  fromField f dat = ColumnName <$> fromField f dat

instance FromField SqlRawOtherConstraintType where
  fromField f dat = do
    t :: String <- fromField f dat
    case t of
      "p" -> pure SQL_raw_pk
      "u" -> pure SQL_raw_unique
      _ -> returnError Pg.ConversionFailed f t

--
-- Postgres queries to extract the schema out of the DB
--

-- | A SQL query to select all user's queries, skipping any beam-related tables (i.e. leftovers from
-- beam-migrate, for example).
userTablesQ :: Pg.Query
userTablesQ =
  fromString $
    unlines
      [ "SELECT cl.oid, relname FROM pg_catalog.pg_class \"cl\" join pg_catalog.pg_namespace \"ns\" ",
        "on (ns.oid = relnamespace) where nspname = any (current_schemas(false)) and relkind='r' ",
        "and relname NOT LIKE 'beam_%'"
      ]

-- | Get information about default values for /all/ tables.
defaultsQ :: Pg.Query
defaultsQ =
  fromString $
    unlines
      [ "SELECT col.table_name::text, col.column_name::text, col.column_default::text, col.data_type::text ",
        "FROM information_schema.columns col ",
        "WHERE col.column_default IS NOT NULL ",
        "AND col.table_schema NOT IN('information_schema', 'pg_catalog') ",
        "ORDER BY col.table_name"
      ]

-- | Get information about columns for this table. Due to the fact this is a query executed for /each/
-- table, is important this is as light as possible to keep the performance decent.
tableColumnsQ :: Pg.Query
tableColumnsQ =
  fromString $
    unlines
      [ "SELECT attname, atttypid, atttypmod, attnotnull, pg_catalog.format_type(atttypid, atttypmod) ",
        "FROM pg_catalog.pg_attribute att ",
        "WHERE att.attrelid=? AND att.attnum>0 AND att.attisdropped='f' "
      ]

-- | Get the enumeration data for all enum types in the database.
enumerationsQ :: Pg.Query
enumerationsQ =
  fromString $
    unlines
      [ "SELECT t.typname, t.oid, array_agg(e.enumlabel ORDER BY e.enumsortorder)",
        "FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid",
        "GROUP BY t.typname, t.oid"
      ]

-- | Get the sequence data for all sequence types in the database.
sequencesQ :: Pg.Query
sequencesQ = fromString "SELECT c.relname FROM pg_class c WHERE c.relkind = 'S'"

-- | Return all foreign key constraints for /all/ 'Table's.
foreignKeysQ :: Pg.Query
foreignKeysQ =
  fromString $
    unlines
      [ "SELECT kcu.table_name::text as foreign_table,",
        "       rel_kcu.table_name::text as primary_table,",
        "       array_agg(kcu.column_name::text ORDER BY kcu.position_in_unique_constraint)::text[] as fk_columns,",
        "       array_agg(rel_kcu.column_name::text ORDER BY rel_kcu.ordinal_position)::text[] as pk_columns,",
        "       kcu.constraint_name as cname",
        "FROM information_schema.table_constraints tco",
        "JOIN information_schema.key_column_usage kcu",
        "          on tco.constraint_schema = kcu.constraint_schema",
        "          and tco.constraint_name = kcu.constraint_name",
        "JOIN information_schema.referential_constraints rco",
        "          on tco.constraint_schema = rco.constraint_schema",
        "          and tco.constraint_name = rco.constraint_name",
        "JOIN information_schema.key_column_usage rel_kcu",
        "          on rco.unique_constraint_schema = rel_kcu.constraint_schema",
        "          and rco.unique_constraint_name = rel_kcu.constraint_name",
        "          and kcu.ordinal_position = rel_kcu.ordinal_position",
        "GROUP BY foreign_table, primary_table, cname"
      ]

-- | Return /all other constraints that are not FKs/ (i.e. 'PRIMARY KEY', 'UNIQUE', etc) for all the tables.
otherConstraintsQ :: Pg.Query
otherConstraintsQ =
  fromString $
    unlines
      [ "SELECT c.conname                                AS constraint_name,",
        "  c.contype                                     AS constraint_type,",
        "  tbl.relname                                   AS \"table\",",
        "  ARRAY_AGG(col.attname ORDER BY u.attposition) AS columns",
        "FROM pg_constraint c",
        "     JOIN LATERAL UNNEST(c.conkey) WITH ORDINALITY AS u(attnum, attposition) ON TRUE",
        "     JOIN pg_class tbl ON tbl.oid = c.conrelid",
        "     JOIN pg_namespace sch ON sch.oid = tbl.relnamespace",
        "     JOIN pg_attribute col ON (col.attrelid = tbl.oid AND col.attnum = u.attnum)",
        "WHERE c.contype = 'u' OR c.contype = 'p'",
        "GROUP BY constraint_name, constraint_type, \"table\"",
        "ORDER BY c.contype"
      ]

-- | Return all \"action types\" for /all/ the constraints.
referenceActionsQ :: Pg.Query
referenceActionsQ =
  fromString $
    unlines
      [ "SELECT c.conname, c. confdeltype, c.confupdtype FROM ",
        "(SELECT r.conrelid, r.confrelid, unnest(r.conkey) AS conkey, unnest(r.confkey) AS confkey, r.conname, r.confupdtype, r.confdeltype ",
        "FROM pg_catalog.pg_constraint r WHERE r.contype = 'f') AS c ",
        "INNER JOIN pg_attribute a_parent ON a_parent.attnum = c.confkey AND a_parent.attrelid = c.confrelid ",
        "INNER JOIN pg_class cl_parent ON cl_parent.oid = c.confrelid ",
        "INNER JOIN pg_namespace sch_parent ON sch_parent.oid = cl_parent.relnamespace ",
        "INNER JOIN pg_attribute a_child ON a_child.attnum = c.conkey AND a_child.attrelid = c.conrelid ",
        "INNER JOIN pg_class cl_child ON cl_child.oid = c.conrelid ",
        "INNER JOIN pg_namespace sch_child ON sch_child.oid = cl_child.relnamespace ",
        "WHERE sch_child.nspname = current_schema() ORDER BY c.conname "
      ]

-- | Connects to a running PostgreSQL database and extract the relevant 'Schema' out of it.
getSchema :: Pg.Connection -> IO Schema
getSchema conn = do
  allTableConstraints <- getAllConstraints conn
  allDefaults <- getAllDefaults conn
  enumerationData <- Pg.fold_ conn enumerationsQ mempty getEnumeration
  sequences <- Pg.fold_ conn sequencesQ mempty getSequence
  tables <-
    Pg.fold_ conn userTablesQ mempty (getTable allDefaults enumerationData allTableConstraints)
  pure $ Schema tables (M.fromList $ M.elems enumerationData) sequences
  where
    getEnumeration ::
      Map Pg.Oid (EnumerationName, Enumeration) ->
      (Text, Pg.Oid, V.Vector Text) ->
      IO (Map Pg.Oid (EnumerationName, Enumeration))
    getEnumeration allEnums (enumName, oid, V.toList -> vals) =
      pure $ M.insert oid (EnumerationName enumName, Enumeration vals) allEnums

    getSequence ::
      Sequences ->
      Pg.Only Text ->
      IO Sequences
    getSequence allSeqs (Pg.Only seqName) =
      case T.splitOn "___" seqName of
        [tName, cName, "seq"] ->
          pure $ M.insert (SequenceName seqName) (Sequence (TableName tName) (ColumnName cName)) allSeqs
        _ -> pure allSeqs

    getTable ::
      AllDefaults ->
      Map Pg.Oid (EnumerationName, Enumeration) ->
      AllTableConstraints ->
      Tables ->
      (Pg.Oid, Text) ->
      IO Tables
    getTable allDefaults enumData allTableConstraints allTables (oid, TableName -> tName) = do
      pgColumns <- Pg.query conn tableColumnsQ (Pg.Only oid)
      newTable <-
        Table (fromMaybe noTableConstraints (M.lookup tName allTableConstraints))
          <$> foldlM (getColumns tName enumData allDefaults) mempty pgColumns
      pure $ M.insert tName newTable allTables

    getColumns ::
      TableName ->
      Map Pg.Oid (EnumerationName, Enumeration) ->
      AllDefaults ->
      Columns ->
      (ByteString, Pg.Oid, Int, Bool, ByteString) ->
      IO Columns
    getColumns tName enumData defaultData c (attname, atttypid, atttypmod, attnotnull, format_type) = do
      -- /NOTA BENE(adn)/: The atttypmod - 4 was originally taken from 'beam-migrate'
      -- (see: https://github.com/tathougies/beam/blob/d87120b58373df53f075d92ce12037a98ca709ab/beam-postgres/Database/Beam/Postgres/Migrate.hs#L343)
      -- but there are cases where this is not correct, for example in the case of bitstrings.
      -- See for example: https://stackoverflow.com/questions/52376045/why-does-atttypmod-differ-from-character-maximum-length
      let mbPrecision =
            if
                | atttypmod == -1 -> Nothing
                | Pg.typoid Pg.bit == atttypid -> Just atttypmod
                | Pg.typoid Pg.varbit == atttypid -> Just atttypmod
                | otherwise -> Just (atttypmod - 4)

      let columnName = ColumnName (TE.decodeUtf8 attname)

      let mbDefault = do
            x <- M.lookup tName defaultData
            M.lookup columnName x

      case asum
        [ pgSerialTyColumnType atttypid mbDefault,
          pgTypeToColumnType atttypid mbPrecision,
          pgEnumTypeToColumnType enumData atttypid
        ] of
        Just cType -> do
          let nullConstraint = if attnotnull then S.fromList [NotNull] else mempty
          let inferredConstraints = nullConstraint <> fromMaybe mempty (S.singleton <$> mbDefault)
          let newColumn = Column cType inferredConstraints
          pure $ M.insert columnName newColumn c
        Nothing ->
          fail $
            "Couldn't convert pgType "
              <> show format_type
              <> " of field "
              <> show attname
              <> " into a valid ColumnType."

--
-- Postgres type mapping
--

pgEnumTypeToColumnType ::
  Map Pg.Oid (EnumerationName, Enumeration) ->
  Pg.Oid ->
  Maybe ColumnType
pgEnumTypeToColumnType enumData oid =
  (\(n, _) -> PgSpecificType (PgEnumeration n)) <$> M.lookup oid enumData

pgSerialTyColumnType ::
  Pg.Oid ->
  Maybe ColumnConstraint ->
  Maybe ColumnType
pgSerialTyColumnType oid (Just (Default d)) = do
  guard $ (Pg.typoid Pg.int4 == oid && "nextval" `T.isInfixOf` d && "seq" `T.isInfixOf` d)
  pure $ SqlStdType intType
pgSerialTyColumnType _ _ = Nothing

-- | Tries to convert from a Postgres' 'Oid' into 'ColumnType'.
-- Mostly taken from [beam-migrate](Database.Beam.Postgres.Migrate).
pgTypeToColumnType :: Pg.Oid -> Maybe Int -> Maybe ColumnType
pgTypeToColumnType oid width
  | Pg.typoid Pg.int2 == oid =
    Just (SqlStdType smallIntType)
  | Pg.typoid Pg.int4 == oid =
    Just (SqlStdType intType)
  | Pg.typoid Pg.int8 == oid =
    Just (SqlStdType bigIntType)
  | Pg.typoid Pg.bpchar == oid =
    Just (SqlStdType $ charType (fromIntegral <$> width) Nothing)
  | Pg.typoid Pg.varchar == oid =
    Just (SqlStdType $ varCharType (fromIntegral <$> width) Nothing)
  | Pg.typoid Pg.bit == oid =
    Just (SqlStdType $ bitType (fromIntegral <$> width))
  | Pg.typoid Pg.varbit == oid =
    Just (SqlStdType $ varBitType (fromIntegral <$> width))
  | Pg.typoid Pg.numeric == oid =
    let decimals = fromMaybe 0 width .&. 0xFFFF
        prec = (fromMaybe 0 width `shiftR` 16) .&. 0xFFFF
     in case (prec, decimals) of
          (0, 0) -> Just (SqlStdType $ numericType Nothing)
          (p, 0) -> Just (SqlStdType $ numericType $ Just (fromIntegral p, Nothing))
          _ -> Just (SqlStdType $ numericType (Just (fromIntegral prec, Just (fromIntegral decimals))))
  | Pg.typoid Pg.float4 == oid =
    Just (SqlStdType realType)
  | Pg.typoid Pg.float8 == oid =
    Just (SqlStdType doubleType)
  | Pg.typoid Pg.date == oid =
    Just (SqlStdType dateType)
  | Pg.typoid Pg.text == oid =
    Just (SqlStdType characterLargeObjectType)
  -- I am not sure if this is a bug in beam-core, but both 'characterLargeObjectType' and 'binaryLargeObjectType'
  -- get mapped into 'AST.DataTypeCharacterLargeObject', which yields TEXT, whereas we want the latter to
  -- yield bytea.
  | Pg.typoid Pg.bytea == oid =
    Just (SqlStdType AST.DataTypeBinaryLargeObject)
  | Pg.typoid Pg.bool == oid =
    Just (SqlStdType booleanType)
  | Pg.typoid Pg.time == oid =
    Just (SqlStdType $ timeType Nothing False)
  | Pg.typoid Pg.timestamp == oid =
    Just (SqlStdType $timestampType Nothing False)
  | Pg.typoid Pg.timestamptz == oid =
    Just (SqlStdType $ timestampType Nothing True)
  | Pg.typoid Pg.json == oid =
    -- json types
    Just (PgSpecificType PgJson)
  | Pg.typoid Pg.jsonb == oid =
    Just (PgSpecificType PgJsonB)
  -- range types
  | Pg.typoid Pg.int4range == oid =
    Just (PgSpecificType PgRangeInt4)
  | Pg.typoid Pg.int8range == oid =
    Just (PgSpecificType PgRangeInt8)
  | Pg.typoid Pg.numrange == oid =
    Just (PgSpecificType PgRangeNum)
  | Pg.typoid Pg.tsrange == oid =
    Just (PgSpecificType PgRangeTs)
  | Pg.typoid Pg.tstzrange == oid =
    Just (PgSpecificType PgRangeTsTz)
  | Pg.typoid Pg.daterange == oid =
    Just (PgSpecificType PgRangeDate)
  | Pg.typoid Pg.uuid == oid =
    Just (PgSpecificType PgUuid)
  | Pg.typoid Pg.oid == oid =
    Just (PgSpecificType PgOid)
  | otherwise =
    Nothing

--
-- Constraints discovery
--

type AllTableConstraints = Map TableName (Set TableConstraint)

type AllDefaults = Map TableName Defaults

type Defaults = Map ColumnName ColumnConstraint

-- Get all defaults values for /all/ the columns.
-- FIXME(adn) __IMPORTANT:__ This function currently __always_ attach an explicit type annotation to the
-- default value, by reading its 'date_type' field, to resolve potential ambiguities.
-- The reason for this is that we cannot reliably guarantee a convertion between default values are read
-- by postgres and values we infer on the Schema side (using the 'beam-core' machinery). In theory we
-- wouldn't need to explicitly annotate the types before generating a 'Default' constraint on the 'Schema'
-- side, but this doesn't always work. For example, if we **always** specify a \"::numeric\" annotation for
-- an 'Int', Postgres might yield \"-1::integer\" for non-positive values and simply \"-1\" for all the rest.
-- To complicate the situation /even if/ we explicitly specify the cast
-- (i.e. \"SET DEFAULT '?::character varying'), Postgres will ignore this when reading the default back.
-- What we do here is obviously not optimal, but on the other hand it's not clear to me how to solve this
-- in a meaningful and non-invasive way, for a number of reasons:
--

-- * For example \"beam-migrate"\ seems to resort to be using explicit serialisation for the types, although

--   I couldn't find explicit trace if that applies for defaults explicitly.
--   (cfr. the \"Database.Beam.AutoMigrate.Serialization\" module in \"beam-migrate\").
--

-- * Another big problem is __rounding__: For example if we insert as \"double precision\" the following:

--   Default "'-0.22030397057804563'" , Postgres will round the value and return Default "'-0.220303970578046'".
--   Again, it's not clear to me how to prevent the users from shooting themselves here.
--

-- * Another quirk is with dates: \"beam\" renders a date like \'1864-05-10\' (note the single quotes) but

--   Postgres strip those when reading the default value back.
--

-- * Range types are also tricky to infer. 'beam-core' escapes the range type name when rendering its default

--   value, whereas Postgres annotates each individual field and yield the unquoted identifier. Compare:
--   1. Beam:     \""numrange"(0, 2, '[)')\"
--   2. Postgres: \"numrange((0)::numeric, (2)::numeric, '[)'::text)\"
--
getAllDefaults :: Pg.Connection -> IO AllDefaults
getAllDefaults conn = Pg.fold_ conn defaultsQ mempty (\acc -> pure . addDefault acc)
  where
    addDefault :: AllDefaults -> (TableName, ColumnName, Text, Text) -> AllDefaults
    addDefault m (tName, colName, defValue, dataType) =
      let cleanedDefault = case T.breakOn "::" defValue of
            (uncasted, defMb)
              | T.null defMb ->
                "'" <> T.dropAround ((==) '\'') uncasted <> "'::" <> dataType
            _ -> defValue
          entry = M.singleton colName (Default cleanedDefault)
       in M.alter
            ( \case
                Nothing -> Just entry
                Just ss -> Just $ ss <> entry
            )
            tName
            m

getAllConstraints :: Pg.Connection -> IO AllTableConstraints
getAllConstraints conn = do
  allActions <- mkActions <$> Pg.query_ conn referenceActionsQ
  allForeignKeys <- Pg.fold_ conn foreignKeysQ mempty (\acc -> pure . addFkConstraint allActions acc)
  Pg.fold_ conn otherConstraintsQ allForeignKeys (\acc -> pure . addOtherConstraint acc)
  where
    addFkConstraint ::
      ReferenceActions ->
      AllTableConstraints ->
      SqlForeignConstraint ->
      AllTableConstraints
    addFkConstraint actions st SqlForeignConstraint {..} = flip execState st $ do
      let currentTable = sqlFk_foreign_table
      let columnSet = S.fromList $ zip (V.toList sqlFk_fk_columns) (V.toList sqlFk_pk_columns)
      let (onDelete, onUpdate) =
            case M.lookup sqlFk_name (getActions actions) of
              Nothing -> (NoAction, NoAction)
              Just a -> (actionOnDelete a, actionOnUpdate a)
      addTableConstraint currentTable (ForeignKey sqlFk_name sqlFk_primary_table columnSet onDelete onUpdate)

    addOtherConstraint ::
      AllTableConstraints ->
      SqlOtherConstraint ->
      AllTableConstraints
    addOtherConstraint st SqlOtherConstraint {..} = flip execState st $ do
      let currentTable = sqlCon_table
      let columnSet = S.fromList . V.toList $ sqlCon_fk_colums
      case sqlCon_constraint_type of
        SQL_raw_unique -> addTableConstraint currentTable (Unique sqlCon_name columnSet)
        SQL_raw_pk -> if S.null columnSet then pure () else
          addTableConstraint currentTable (PrimaryKey sqlCon_name columnSet)

newtype ReferenceActions = ReferenceActions {getActions :: Map Text Actions}

newtype RefEntry = RefEntry {unRefEntry :: (Text, ReferenceAction, ReferenceAction)}

mkActions :: [RefEntry] -> ReferenceActions
mkActions = ReferenceActions . M.fromList . map ((\(a, b, c) -> (a, Actions b c)) . unRefEntry)

instance Pg.FromRow RefEntry where
  fromRow =
    fmap
      RefEntry
      ( (,,) <$> field
          <*> fmap mkAction field
          <*> fmap mkAction field
      )

data Actions = Actions
  { actionOnDelete :: ReferenceAction,
    actionOnUpdate :: ReferenceAction
  }

mkAction :: Text -> ReferenceAction
mkAction c = case c of
  "a" -> NoAction
  "r" -> Restrict
  "c" -> Cascade
  "n" -> SetNull
  "d" -> SetDefault
  _ -> error . T.unpack $ "unknown reference action type: " <> c

--
-- Useful combinators to add constraints for a column or table if already there.
--

addTableConstraint ::
  TableName ->
  TableConstraint ->
  State AllTableConstraints ()
addTableConstraint tName cns =
  modify'
    ( M.alter
        ( \case
            Nothing -> Just $ S.singleton cns
            Just ss -> Just $ S.insert cns ss
        )
        tName
    )
