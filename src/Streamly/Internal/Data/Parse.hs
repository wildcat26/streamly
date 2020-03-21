{-# LANGUAGE BangPatterns              #-}
{-# LANGUAGE CPP                       #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      : Streamly.Internal.Data.Parse
-- Copyright   : (c) 2019 Composewell Technologies
-- License     : BSD3
-- Maintainer  : streamly@composewell.com
-- Stability   : experimental
-- Portability : GHC
--
-- Parsers.

module Streamly.Internal.Data.Parse
    (
      Parse (..)

    -- * Parsers
    , any
    , all

    , takeWhile
    , takeExact
    , takeAtLeast

    , endOn
    , endAfter
    , endBefore

    , finishBy
    )
where

import Prelude
       hiding (any, all, takeWhile)
import Streamly.Internal.Data.Parse.Types (Parse(..), Step(..))
import Streamly.Internal.Data.Fold.Types (Fold(..))

import Streamly.Internal.Data.Strict

-------------------------------------------------------------------------------
-- Terminating folds
-------------------------------------------------------------------------------
--
-- XXX any/all should be terminating folds when we have a terminating fold
-- type.
--
-- >>> S.parse (PR.any (== 0)) $ S.fromList [1,0,1]
-- > Right True
--
{-# INLINABLE any #-}
any :: Monad m => (a -> Bool) -> Parse m a Bool
any predicate = Parse step initial (\x -> return $ Right (0,x))
    where
    initial = return False
    step s a = return $
        if s
        then Halt True
        else
            if predicate a
            then Halt True
            else Keep 0 False

-- >>> S.parse (PR.any (== 0)) $ S.fromList [1,0,1]
-- > Right False
--
{-# INLINABLE all #-}
all :: Monad m => (a -> Bool) -> Parse m a Bool
all predicate = Parse step initial (\x -> return $ Right (0,x))
    where
    initial = return True
    step s a = return $
        if s
        then
            if predicate a
            then Keep 0 True
            else Halt False
        else Halt False

-------------------------------------------------------------------------------
-- Taking elements
-------------------------------------------------------------------------------
--
-- | Stops after taking exactly @n@ input elements.
--
-- * Stops - after @n@ elements.
-- * Fails - if the stream ends before it can collect @n@ elements.
--
-- >>> S.parse (PR.takeExact 4 FL.toList) $ S.fromList [1,0,1]
-- > Left "takeExact: Expecting exactly 4 elements, got 3"
--
-- /Internal/
--
{-# INLINABLE takeExact #-}
takeExact :: Monad m => Int -> Fold m a b -> Parse m a b
takeExact n (Fold fstep finitial fextract) = Parse step initial extract

    where

    initial = (Tuple' 0) <$> finitial

    step (Tuple' i r) a = do
        res <- fstep r a
        let i1 = i + 1
            s1 = Tuple' i1 res
        return $ if i1 < n then Hold s1 else Halt s1

    extract (Tuple' i r) = fmap f (fextract r)

        where

        err =
               "takeExact: Expecting exactly " ++ show n
            ++ " elements, got " ++ show i

        f x =
            if n == i
            then Right (0, x)
            else Left err

-- | Take at least @n@ input elements, but can collect more.
--
-- * Stops - never.
-- * Fails - if the stream end before producing @n@ elements.
--
-- >>> S.parse (PR.takeAtLeast 4 FL.toList) $ S.fromList [1,0,1]
-- > Left "takeAtLeast: Expecting at least 4 elements, got only 3"
--
-- >>> S.parse (PR.takeAtLeast 4 FL.toList) $ S.fromList [1,0,1,0,1]
-- > Right [1,0,1,0,1]
--
-- /Internal/
--
{-# INLINABLE takeAtLeast #-}
takeAtLeast :: Monad m => Int -> Fold m a b -> Parse m a b
takeAtLeast n (Fold fstep finitial fextract) = Parse step initial extract

    where

    initial = (Tuple' 0) <$> finitial

    step (Tuple' i r) a = do
        res <- fstep r a
        let i1 = i + 1
            s1 = Tuple' i1 res
        return $ Hold s1

    extract (Tuple' i r) = fmap f (fextract r)

        where

        err =
              "takeAtLeast: Expecting at least " ++ show n
           ++ " elements, got only " ++ show i

        f x =
            if i >= n
            then Right (0, x)
            else Left err

-- | Take until the predicate fails. Does not take the failing element.
--
-- * Stops - when the predicate fails.
-- * Fails - never.
--
-- >>> S.parse (PR.takeWhile (== 0) FL.toList) $ S.fromList [0,0,1,0,1]
-- > Right [0,0]
--
-- /Internal/
--
{-# INLINABLE takeWhile #-}
takeWhile :: Monad m => (a -> Bool) -> Fold m a b -> Parse m a b
takeWhile predicate (Fold fstep finitial fextract) =
    Parse step initial extract

    where

    initial = finitial
    step s a = do
        if predicate a
        then Keep 0 <$> fstep s a
        else return $ Halt s
    extract s = do
        b <- fextract s
        return $ Right (1, b)

-- | Keep taking elements until the predicate succeeds. Drop the succeeding
-- element.
--
-- * Stops - when the predicate succeeds.
-- * Fails - never.
--
-- >>> S.parse (PR.endOn (== 1) FL.toList) $ S.fromList [0,0,1,0,1]
-- > Right [0,0]
--
-- >>> S.toList $ S.parseChunks (PR.endOn (== 1) FL.toList) $ S.fromList [0,0,1,0,1]
-- > [[0,0],[0],[]]
--
-- /Internal/
--
{-# INLINABLE endOn #-}
endOn :: Monad m => (a -> Bool) -> Fold m a b -> Parse m a b
endOn predicate (Fold fstep finitial fextract) =
    Parse step initial extract

    where

    initial = finitial
    step s a = do
        if not (predicate a)
        then Keep 0 <$> fstep s a
        else return $ Halt s
    extract s = do
        b <- fextract s
        return $ Right (0, b)

-- | Keep taking elements until the predicate succeeds. Take the succeeding
-- element as well.
--
-- * Stops - when the predicate succeeds.
-- * Fails - never.
--
-- /Unimplemented/
--
{-# INLINABLE endAfter #-}
endAfter ::
    -- Monad m =>
    (a -> Bool) -> Fold m a b -> Parse m a b
endAfter = undefined

-- | Keep taking elements until the predicate succeeds. Return the succeeding
-- element back to the input.
--
-- * Stops - when the predicate succeeds.
-- * Fails - never.
--
-- /Unimplemented/
--
{-# INLINABLE endBefore #-}
endBefore ::
    -- Monad m =>
    (a -> Bool) -> Fold m a b -> Parse m a b
endBefore = undefined

-- | Distribute the input to a parse and a fold until the parse succeeds or
-- fails. The parse can be used to decide the termination of the fold.
--
-- /Unimplemented/
--
finishBy :: Parse m a x -> Fold m a y -> Parse m a (x, y)
finishBy = undefined