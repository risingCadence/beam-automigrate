{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE FlexibleContexts     #-}
{-# LANGUAGE LambdaCase           #-}
module Database.Beam.Migrate
  ( fromAnnotatedDbSettings
  , defaultAnnotatedDbSettings
  -- * Converting from an annotated to a simple 'DatabaseSettings'
  , deAnnotateDatabase
  -- * Migrations
  , Migration
  , migrate
  , runMigration
  , printMigration
  , createMigration
    -- * Handy re-exports
  , module Exports
  )
where

import           Control.Exception                        ( throwIO )
import           Control.Monad.Identity                   (runIdentity)
import           Control.Monad.State.Strict
import           Control.Monad.Except
import           Control.Monad.IO.Class                   ( liftIO
                                                          , MonadIO
                                                          )
import           Lens.Micro                               ( (^.) )
import           Data.Proxy
import           Data.String.Conv                         ( toS )
import           Data.String                              ( fromString )
import qualified Data.List                               as L
import qualified Data.List.NonEmpty                      as NE
import qualified Data.Set                                as S
import qualified Data.Map.Strict                         as M
import           Data.Text                                ( Text )
import qualified Data.Text                               as T
import qualified Data.Text.Encoding                      as TE

import           GHC.Generics                      hiding ( prec )


import           Database.Beam                            ( MonadBeam )
import           Database.Beam.Schema                     ( Database
                                                          , DatabaseSettings
                                                          )
import           Database.Beam.Schema.Tables              ( DatabaseEntity(..)
                                                          )

import           Database.Beam.Migrate.Annotated         as Exports
import           Database.Beam.Migrate.Generic           as Exports
import           Database.Beam.Migrate.Types             as Exports
import           Database.Beam.Migrate.Diff              as Exports
import           Database.Beam.Migrate.Postgres           ( getSchema )
import qualified Database.Beam.Backend.SQL.AST           as AST

import           Database.Beam.Backend.SQL         hiding ( tableName )

import qualified Database.Beam.Postgres                  as Pg
import qualified Database.Beam.Postgres.Syntax           as Pg

--
-- Potential API (sketched)
--

-- | Turns a Beam's 'DatabaseSettings' into an 'AnnotatedDatabaseSettings'.
defaultAnnotatedDbSettings :: forall be db. 
                           ( Generic (db (DatabaseEntity be db))
                           , Generic (db (AnnotatedDatabaseEntity be db))
                           , Database be db 
                           , GZipDatabase be (DatabaseEntity be db)
                                             (AnnotatedDatabaseEntity be db)
                                             (AnnotatedDatabaseEntity be db)
                                             (Rep (db (DatabaseEntity be db)))
                                             (Rep (db (AnnotatedDatabaseEntity be db)))
                                             (Rep (db (AnnotatedDatabaseEntity be db)))
                           )
                           => DatabaseSettings be db 
                           -> AnnotatedDatabaseSettings be db
defaultAnnotatedDbSettings db = runIdentity $
  zipTables (Proxy @be) annotate db (undefined :: AnnotatedDatabaseSettings be db)
  where

    annotate :: ( Monad m
                , IsAnnotatedDatabaseEntity be ty
                , AnnotatedDatabaseEntityRegularRequirements be ty)
             => DatabaseEntity be db ty 
             -> AnnotatedDatabaseEntity be db ty 
             -> m (AnnotatedDatabaseEntity be db ty)
    annotate (DatabaseEntity edesc) _ = 
        pure $ AnnotatedDatabaseEntity (dbAnnotatedEntityAuto edesc) (DatabaseEntity edesc)

deAnnotateDatabase :: forall be db. 
                   ( Database be db 
                   , Generic (db (DatabaseEntity be db))
                   , Generic (db (AnnotatedDatabaseEntity be db))
                   , GZipDatabase be (AnnotatedDatabaseEntity be db)
                                     (AnnotatedDatabaseEntity be db)
                                     (DatabaseEntity be db)
                                     (Rep (db (AnnotatedDatabaseEntity be db)))
                                     (Rep (db (AnnotatedDatabaseEntity be db)))
                                     (Rep (db (DatabaseEntity be db)))
                   )
                   => AnnotatedDatabaseSettings be db 
                   -> DatabaseSettings be db
deAnnotateDatabase db = 
    runIdentity $ zipTables (Proxy @be) (\ann _ -> pure $ ann ^. deannotate) db db

-- | Turns an 'AnnotatedDatabaseSettings' into a 'Schema'.
fromAnnotatedDbSettings :: ( Database be db
                           , Generic (db (DatabaseEntity be db))
                           , Generic (db (AnnotatedDatabaseEntity be db))
                           , GZipDatabase be (AnnotatedDatabaseEntity be db)
                                             (AnnotatedDatabaseEntity be db)
                                             (DatabaseEntity be db)
                                             (Rep (db (AnnotatedDatabaseEntity be db)))
                                             (Rep (db (AnnotatedDatabaseEntity be db)))
                                             (Rep (db (DatabaseEntity be db)))
                           , Generic (AnnotatedDatabaseSettings be db)
                           , GSchema be db (Rep (AnnotatedDatabaseSettings be db))
                           )
                        => AnnotatedDatabaseSettings be db 
                        -> Schema
fromAnnotatedDbSettings db = gSchema db (from db)

data SequencedEdits = SequencedEdits {
    seCreationsOrDeletions :: [Edit]
  , seAlterations :: [Edit]
  }

-- | Partion edits in "additions" and "removals" operations, to make sure we do not try to
-- reference something which hasn't been created yet.
-- FIXME(adn) Until we fix #1 properly, we also filter 'IsForeignKeyOf' entries.
toSequencedEdits :: [Edit] -> SequencedEdits
toSequencedEdits edits =
    let (seCreationsOrDeletions, alterations) = partitionEdits edits
        in SequencedEdits { seCreationsOrDeletions, seAlterations = filter (not . isForeignKeyOf) alterations }
  where
    partitionEdits :: [Edit] -> ([Edit], [Edit])
    partitionEdits = L.partition isCreationOrDeletion
      where
          isCreationOrDeletion :: Edit -> Bool
          isCreationOrDeletion = \case
            TableAdded _ _ -> True
            TableRemoved _ -> True
            ColumnAdded _ _ _ -> True
            ColumnRemoved _ _ -> True
            _                 -> False

    isForeignKeyOf :: Edit -> Bool
    isForeignKeyOf = \case
      TableConstraintAdded   _ IsForeignKeyOf{} -> True
      TableConstraintRemoved _ IsForeignKeyOf{} -> True
      _ -> False

editsToPgSyntax :: SequencedEdits -> [Pg.PgSyntax]
editsToPgSyntax SequencedEdits{seCreationsOrDeletions, seAlterations} =
  map toSqlSyntax (seCreationsOrDeletions <> seAlterations)

-- | A database 'Migration'.
type Migration m = ExceptT DiffError (StateT [Edit] m) ()

migrate :: MonadIO m => Pg.Connection -> Schema -> Migration m
migrate conn hsSchema = do
    dbSchema <- lift . liftIO $ getSchema conn
    let schemaDiff = diff hsSchema dbSchema
    case schemaDiff of
      Left e -> throwError e
      Right edits -> lift (put edits)

-- | Runs the input 'Migration'.
-- NOTE(adn) Currently this works only against the \"beam-postgres\" backend, as we are using the concrete
-- 'PgCommandSyntax' here.
runMigration :: (MonadBeam Pg.Postgres m, MonadIO m) => Migration m -> m ()
runMigration m = do
  migs <- evalMigration m
  case migs of
    Left e -> liftIO $ throwIO e
    Right (toSequencedEdits -> edits) -> 
      runNoReturn $ Pg.PgCommandSyntax Pg.PgCommandTypeDdl (mconcat . editsToPgSyntax $ edits)

-- Pg.PgCommandSyntax Pg.PgCommandTypeDdl 

toSqlSyntax :: Edit -> Pg.PgSyntax
toSqlSyntax = \case
  TableAdded tblName tbl -> 
      ddlSyntax ("CREATE TABLE " <> sqlEscaped (tableName tblName )
                                   <> " (" 
                                   <> T.intercalate ", " (map renderTableColumn (M.toList (tableColumns tbl)) <>
                                                          filter (not . T.null) (map renderCreateTableConstraint (S.toList (tableConstraints tbl)))
                                                         )
                                   <> ")"
                )
  TableRemoved tblName    ->
      ddlSyntax ("DROP TABLE " <> sqlEscaped (tableName tblName))
  TableConstraintAdded  tblName cstr ->
      updateSyntax (alterTable tblName <> renderAddConstraint cstr)
  TableConstraintRemoved tblName cstr ->
      updateSyntax (alterTable tblName <> renderDropConstraint cstr)
  EnumTypeAdded tyName vals -> createTypeSyntax tyName vals
  ColumnAdded tblName colName col ->
      updateSyntax (alterTable tblName 
                                <> "ADD COLUMN "
                                <> sqlEscaped (columnName colName)
                                <> " "
                                <> renderDataType (columnType col)
                                <> " "
                                <> T.intercalate " " (map renderColumnConstraint (S.toList $ columnConstraints col))
                   )
  ColumnRemoved tblName colName ->
      updateSyntax (alterTable tblName <> "DROP COLUMN " <> sqlEscaped (columnName colName))
  ColumnTypeChanged tblName colName _old new ->
      updateSyntax (alterTable tblName <> "ALTER COLUMN " <> sqlEscaped (columnName colName) <> " TYPE " <> renderDataType new)
  ColumnConstraintAdded tblName colName cstr ->
      updateSyntax (alterTable tblName <> "ALTER COLUMN " <> sqlEscaped (columnName colName) <> " SET " <> renderColumnConstraint cstr)
  ColumnConstraintRemoved tblName colName cstr ->
      updateSyntax (alterTable tblName <> "ALTER COLUMN " <> sqlEscaped (columnName colName) <> " DROP " <> renderColumnConstraint cstr)
  where
      ddlSyntax query    = Pg.emit . TE.encodeUtf8 $ query <> ";\n"
      updateSyntax query = Pg.emit . TE.encodeUtf8 $ query <> ";\n"

      alterTable :: TableName -> Text
      alterTable (TableName tName) = "ALTER TABLE " <> sqlEscaped tName <> " " 

      renderTableColumn :: (ColumnName, Column) -> Text
      renderTableColumn (colName, col) = columnName colName <> " " <> renderDataType (columnType col)

      renderCreateTableConstraint :: TableConstraint -> Text
      renderCreateTableConstraint = \case
        Unique fname cols -> 
            conKeyword <> sqlEscaped fname 
                       <> " UNIQUE (" 
                       <> T.intercalate ", " (map columnName (S.toList cols)) 
                       <> ")"
        PrimaryKey fname cols -> 
            conKeyword <> sqlEscaped fname 
                       <> "PRIMARY KEY (" 
                       <> T.intercalate ", " (map columnName (S.toList cols)) 
                       <> ")"
        ForeignKey fname (tableName -> tName) (S.toList -> colPair) onDelete onUpdate ->
            let (fkCols, referenced) = (map (columnName . fst) colPair, map (columnName . snd) colPair)
            in conKeyword <> sqlEscaped fname 
                          <> " FOREIGN KEY (" 
                          <> T.intercalate ", " fkCols
                          <> ") REFERENCES " <> sqlEscaped tName 
                          <> "(" <> T.intercalate ", " referenced <> ")" 
                          <> renderAction "ON DELETE" onDelete 
                          <> renderAction "ON UPDATE" onUpdate
        IsForeignKeyOf _tName _cols -> mempty
        where conKeyword = "CONSTRAINT "

      renderAddConstraint :: TableConstraint -> Text
      renderAddConstraint tc = case tc of
        IsForeignKeyOf{} -> mempty
        _ -> accC (renderCreateTableConstraint tc)
        where accC = mappend "ADD "

      renderDropConstraint :: TableConstraint -> Text
      renderDropConstraint tc = case tc of
        IsForeignKeyOf{}         -> mempty
        Unique     cName _       -> dropC cName
        PrimaryKey cName _       -> dropC cName
        ForeignKey cName _ _ _ _ -> dropC cName
        where dropC = mappend "DROP CONSTRAINT "

      renderAction actionPrefix = \case
        NoAction   -> mempty
        Cascade    -> " " <> actionPrefix <> " " <> "CASCADE "
        Restrict   -> " " <> actionPrefix <> " " <> "RESTRICT "
        SetNull    -> " " <> actionPrefix <> " " <> "SET NULL "
        SetDefault -> " " <> actionPrefix <> " " <> "SET DEFAULT "

      renderColumnConstraint :: ColumnConstraint -> Text
      renderColumnConstraint = \case
        NotNull -> "NOT NULL"
        Default defValue -> "DEFAULT " <> defValue

      createTypeSyntax :: EnumerationName -> Enumeration -> Pg.PgSyntax
      createTypeSyntax (EnumerationName ty) (Enumeration (NE.toList -> vals)) = Pg.emit $ toS $
          "CREATE TYPE " <> sqlEscaped ty <> " AS ENUM (" <> T.intercalate "," (map sqlSingleQuoted vals) <> ");\n"

      -- This function also overlaps with beam-migrate functionalities.
      renderDataType :: ColumnType -> Text
      renderDataType = \case
        SqlStdType (AST.DataTypeChar varying prec charSet) ->
            let ty = if varying then "VARCHAR" else "CHAR"
            in ty <> sqlOptPrec prec <> sqlOptCharSet charSet
        SqlStdType (AST.DataTypeNationalChar varying prec) ->
            let ty = if varying then "NATIONAL CHARACTER VARYING" else "NATIONAL CHAR"
            in ty <> sqlOptPrec prec
        SqlStdType (AST.DataTypeBit varying prec) ->
            let ty = if varying then "BIT VARYING" else "BIT"
            in ty <> sqlOptPrec prec
        SqlStdType (AST.DataTypeNumeric prec) -> "NUMERIC" <> sqlOptNumericPrec prec
        SqlStdType (AST.DataTypeDecimal prec) -> "DOUBLE" <> sqlOptNumericPrec prec
        SqlStdType (AST.DataTypeInteger) -> "INT"
        SqlStdType (AST.DataTypeSmallInt) -> "SMALLINT"
        SqlStdType (AST.DataTypeBigInt) -> "BIGINT"
        SqlStdType (AST.DataTypeFloat prec) -> "FLOAT" <> sqlOptPrec prec
        SqlStdType (AST.DataTypeReal) -> "REAL"
        SqlStdType (AST.DataTypeDoublePrecision) -> "DOUBLE PRECISION"
        SqlStdType (AST.DataTypeDate) -> "DATE"
        SqlStdType (AST.DataTypeTime prec withTz) ->
          let ty = "TIME" <> sqlOptPrec prec <> if withTz then " WITH TIME ZONE" else mempty
          in ty <> sqlOptPrec prec
        SqlStdType (AST.DataTypeTimeStamp prec withTz) ->
          let ty = "TIMESTAMP" <> sqlOptPrec prec <> if withTz then " WITH TIME ZONE" else mempty
          in ty <> sqlOptPrec prec
        SqlStdType (AST.DataTypeInterval _i) -> error "DataTypeInterval not supported yet."
        SqlStdType (AST.DataTypeIntervalFromTo _from _to) -> error "DataTypeIntervalFromTo not supported yet."
        SqlStdType AST.DataTypeBoolean -> "BOOL"
        SqlStdType AST.DataTypeBinaryLargeObject ->
            error "DataTypeBinaryLargeObject not supported yet."
        SqlStdType AST.DataTypeCharacterLargeObject ->
            error "DataTypeCharacterLargeObject not supported yet."
        SqlStdType (AST.DataTypeArray _dt _int) ->
            error "DataTypeArray not supported yet."
        SqlStdType (AST.DataTypeRow _rows) ->
            error "DataTypeRow not supported yet."
        SqlStdType (AST.DataTypeDomain nm) -> "\"" <> nm <> "\""
        -- Json types
        PgSpecificType PgJson  -> "JSON"
        PgSpecificType PgJsonB -> "JSONB"
        -- Range types
        PgSpecificType PgRangeInt4 -> toS $ Pg.rangeName @Pg.PgInt4Range
        PgSpecificType PgRangeInt8 -> toS $ Pg.rangeName @Pg.PgInt8Range
        PgSpecificType PgRangeNum  -> toS $ Pg.rangeName @Pg.PgNumRange
        PgSpecificType PgRangeTs   -> toS $ Pg.rangeName @Pg.PgTsRange
        PgSpecificType PgRangeTsTz -> toS $ Pg.rangeName @Pg.PgTsTzRange
        PgSpecificType PgRangeDate -> toS $ Pg.rangeName @Pg.PgDateRange
        -- enumerations
        PgSpecificType (PgEnumeration (EnumerationName ty)) -> ty


-- NOTE(adn) Unfortunately these combinators are not re-exported by beam.

sqlOptPrec :: Maybe Word -> Text
sqlOptPrec Nothing = mempty
sqlOptPrec (Just x) = "(" <> fromString (show x) <> ")"

sqlOptCharSet :: Maybe Text -> Text
sqlOptCharSet Nothing = mempty
sqlOptCharSet (Just cs) = " CHARACTER SET " <> cs

sqlEscaped :: Text -> Text
sqlEscaped t = "\"" <> t <> "\""

sqlSingleQuoted :: Text -> Text
sqlSingleQuoted t = "'" <> t <> "'"

sqlOptNumericPrec :: Maybe (Word, Maybe Word) -> Text
sqlOptNumericPrec Nothing = mempty
sqlOptNumericPrec (Just (prec, Nothing)) = sqlOptPrec (Just prec)
sqlOptNumericPrec (Just (prec, Just dec)) = "(" <> fromString (show prec) <> ", " <> fromString (show dec) <> ")"

evalMigration :: Monad m => Migration m -> m (Either DiffError [Edit])
evalMigration m = do
    (a, s) <- runStateT (runExceptT m) mempty
    case a of
      Left e    -> pure (Left e)
      Right ()  -> pure (Right s)

-- | Create the migration from a 'Diff'.
createMigration :: Monad m => Diff -> Migration m
createMigration (Left e) = throwError e
createMigration (Right edits) = ExceptT $ do
    put edits
    pure (Right ())

-- | Prints the migration to stdout. Useful for debugging and diagnostic.
printMigration :: MonadIO m => Migration m -> m ()
printMigration m = do
    (a, sequencedEdits) <- fmap toSequencedEdits <$> runStateT (runExceptT m) mempty
    case a of
      Left e    -> liftIO $ throwIO e
      Right ()  -> liftIO $ putStrLn (unlines . map displaySyntax $ editsToPgSyntax sequencedEdits)
