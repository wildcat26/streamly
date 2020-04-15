{-# LANGUAGE CPP                       #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}

-- |
-- Module      : Streamly.Internal.Data.Fold.Types
-- Copyright   : (c) 2019 Composewell Technologies
--               (c) 2013 Gabriel Gonzalez
-- License     : BSD3
-- Maintainer  : streamly@composewell.com
-- Stability   : experimental
-- Portability : GHC

module Streamly.Internal.Data.Fold.Types
    ( Step (..)
    , fmap1
    , fmap2
    , stepWS
    , doneWS
    , initialTS
    , initialTSM
    , Fold (..)

    , Fold2 (..)
    , simplify
    , toListRevF  -- experimental

    , lmap
    , lmapM
    , lfilter
    , lfilterM
    , lcatMaybes
    , ltake
    , ltakeWhile
    , lsessionsOf
    , lchunksOf
    , lchunksOf2

    , duplicate
    , initialize
    , runStep
    )
where

import Control.Applicative (liftA2)
import Control.Concurrent (threadDelay, forkIO, killThread)
import Control.Concurrent.MVar (MVar, newMVar, takeMVar, putMVar)
import Control.Exception (SomeException(..), catch, mask)
import Control.Monad (void)
import Control.Monad.Catch (throwM)
import Control.Monad.IO.Class (MonadIO(..))
import Control.Monad.Trans.Control (control)
import Data.Maybe (isJust, fromJust)
#if __GLASGOW_HASKELL__ < 808
import Data.Semigroup (Semigroup(..))
#endif
import Streamly.Internal.Data.Strict (Tuple'(..), Tuple3'(..), Either'(..))
import Streamly.Internal.Data.SVar (MonadAsync)

------------------------------------------------------------------------------
-- Monadic left folds
------------------------------------------------------------------------------

-- {-# ANN type Step Fuse #-}
data Step s b = Yield s | Stop b

{-# INLINE fmap1 #-}
fmap1 :: (a -> b) -> Step a x -> Step b x
fmap1 f (Yield a) = Yield (f a)
fmap1 _ (Stop x) = Stop x

{-# INLINE fmap2 #-}
fmap2 :: (a -> b) -> Step x a -> Step x b
fmap2 f (Stop a) = Stop (f a)
fmap2 _ (Yield x) = Yield x

instance Functor (Step s) where
    {-# INLINE fmap #-}
    fmap = fmap2

-- | Represents a left fold over an input stream of values of type @a@ to a
-- single value of type @b@ in 'Monad' @m@.
--
-- The fold uses an intermediate state @s@ as accumulator. The @step@ function
-- updates the state and returns the new updated state. When the fold is done
-- the final result of the fold is extracted from the intermediate state
-- representation using the @extract@ function.
--
-- @since 0.7.0

data Fold m a b =
  -- | @Fold @ @ step @ @ initial @ @ extract@
  forall s. Fold (s -> a -> m (Step s b)) (m s) (s -> m b)

{-# INLINE stepWS #-}
stepWS :: Monad m => (s -> a -> m (Step s b)) -> Step s b -> a -> m (Step s b)
stepWS step (Yield s) a = step s a
stepWS _ x _ = return x

{-# INLINE doneWS #-}
doneWS :: Monad m => (s -> m b) -> Step s b -> m b
doneWS _ (Stop b) = return b
doneWS done (Yield s) = done s

{-# INLINE initialTS #-}
initialTS :: s -> Step s b
initialTS = Yield

{-# INLINE initialTSM #-}
initialTSM :: Monad m => m s -> m (Step s b)
initialTSM = fmap Yield


-- Experimental type to provide a side input to the fold for generating the
-- initial state. For example, if we have to fold chunks of a stream and write
-- each chunk to a different file, then we can generate the file name using a
-- monadic action. This is a generalized version of 'Fold'.
--
data Fold2 m c a b =
  -- | @Fold @ @ step @ @ inject @ @ extract@
  forall s. Fold2 (s -> a -> m s) (c -> m s) (s -> m b)

-- | Convert more general type 'Fold2' into a simpler type 'Fold'
simplify :: Functor m => Fold2 m c a b -> c -> Fold m a b
simplify (Fold2 step inject extract) c =
    Fold (\x a -> Yield <$> step x a) (inject c) extract

-- | Maps a function on the output of the fold (the type @b@).
instance Monad m => Functor (Fold m a) where
    {-# INLINE fmap #-}
    fmap f (Fold step start done) = Fold step' start done'
        where
        step' x a = do
            res <- step x a
            case res of
                Yield s -> return $ Yield s
                Stop b -> return $ Stop (f b)
        done' x = fmap f $! done x

-- | The fold resulting from '<*>' distributes its input to both the argument
-- folds and combines their output using the supplied function.
instance Monad m => Applicative (Fold m a) where
    {-# INLINE pure #-}
    pure b = Fold (\() _ -> pure $ Stop b) (pure ()) (\() -> pure b)
    {-# INLINE (<*>) #-}
    (Fold stepL beginL doneL) <*> (Fold stepR beginR doneR) =
        let combine (Stop dL) (Stop dR) = Stop $ dL dR
            combine sl sr = Yield $ Tuple' sl sr
            step (Tuple' xL xR) a =
                combine <$> stepWS stepL xL a <*> stepWS stepR xR a
            begin = Tuple' <$> initialTSM beginL <*> initialTSM beginR
            done (Tuple' xL xR) = doneWS doneL xL <*> doneWS doneR xR
         in Fold step begin done

-- | Combines the outputs of the folds (the type @b@) using their 'Semigroup'
-- instances.
instance (Semigroup b, Monad m) => Semigroup (Fold m a b) where
    {-# INLINE (<>) #-}
    (<>) = liftA2 (<>)

-- | Combines the outputs of the folds (the type @b@) using their 'Monoid'
-- instances.
instance (Semigroup b, Monoid b, Monad m) => Monoid (Fold m a b) where
    {-# INLINE mempty #-}
    mempty = pure mempty

    {-# INLINE mappend #-}
    mappend = (<>)

-- | Combines the fold outputs (type @b@) using their 'Num' instances.
instance (Monad m, Num b) => Num (Fold m a b) where
    {-# INLINE fromInteger #-}
    fromInteger = pure . fromInteger

    {-# INLINE negate #-}
    negate = fmap negate

    {-# INLINE abs #-}
    abs = fmap abs

    {-# INLINE signum #-}
    signum = fmap signum

    {-# INLINE (+) #-}
    (+) = liftA2 (+)

    {-# INLINE (*) #-}
    (*) = liftA2 (*)

    {-# INLINE (-) #-}
    (-) = liftA2 (-)

-- | Combines the fold outputs (type @b@) using their 'Fractional' instances.
instance (Monad m, Fractional b) => Fractional (Fold m a b) where
    {-# INLINE fromRational #-}
    fromRational = pure . fromRational

    {-# INLINE recip #-}
    recip = fmap recip

    {-# INLINE (/) #-}
    (/) = liftA2 (/)

-- | Combines the fold outputs using their 'Floating' instances.
instance (Monad m, Floating b) => Floating (Fold m a b) where
    {-# INLINE pi #-}
    pi = pure pi

    {-# INLINE exp #-}
    exp = fmap exp

    {-# INLINE sqrt #-}
    sqrt = fmap sqrt

    {-# INLINE log #-}
    log = fmap log

    {-# INLINE sin #-}
    sin = fmap sin

    {-# INLINE tan #-}
    tan = fmap tan

    {-# INLINE cos #-}
    cos = fmap cos

    {-# INLINE asin #-}
    asin = fmap asin

    {-# INLINE atan #-}
    atan = fmap atan

    {-# INLINE acos #-}
    acos = fmap acos

    {-# INLINE sinh #-}
    sinh = fmap sinh

    {-# INLINE tanh #-}
    tanh = fmap tanh

    {-# INLINE cosh #-}
    cosh = fmap cosh

    {-# INLINE asinh #-}
    asinh = fmap asinh

    {-# INLINE atanh #-}
    atanh = fmap atanh

    {-# INLINE acosh #-}
    acosh = fmap acosh

    {-# INLINE (**) #-}
    (**) = liftA2 (**)

    {-# INLINE logBase #-}
    logBase = liftA2 logBase

------------------------------------------------------------------------------
-- Internal APIs
------------------------------------------------------------------------------

-- This is more efficient than 'toList'. toList is exactly the same as
-- reversing the list after toListRev.
--
-- | Buffers the input stream to a list in the reverse order of the input.
--
-- /Warning!/ working on large lists accumulated as buffers in memory could be
-- very inefficient, consider using "Streamly.Array" instead.
--
-- @since 0.7.0

--  xn : ... : x2 : x1 : []
{-# INLINABLE toListRevF #-}
toListRevF :: Monad m => Fold m a [a]
toListRevF = Fold (\xs x -> return $ Yield $ x:xs) (return []) return

-- | @(lmap f fold)@ maps the function @f@ on the input of the fold.
--
-- >>> S.fold (FL.lmap (\x -> x * x) FL.sum) (S.enumerateFromTo 1 100)
-- 338350
--
-- @since 0.7.0
{-# INLINABLE lmap #-}
lmap :: (a -> b) -> Fold m b r -> Fold m a r
lmap f (Fold step begin done) = Fold step' begin done
  where
    step' x a = step x (f a)

-- | @(lmapM f fold)@ maps the monadic function @f@ on the input of the fold.
--
-- @since 0.7.0
{-# INLINABLE lmapM #-}
lmapM :: Monad m => (a -> m b) -> Fold m b r -> Fold m a r
lmapM f (Fold step begin done) = Fold step' begin done
  where
    step' x a = f a >>= step x

------------------------------------------------------------------------------
-- Filtering
------------------------------------------------------------------------------

-- | Include only those elements that pass a predicate.
--
-- >>> S.fold (lfilter (> 5) FL.sum) [1..10]
-- 40
--
-- @since 0.7.0
{-# INLINABLE lfilter #-}
lfilter :: Monad m => (a -> Bool) -> Fold m a r -> Fold m a r
lfilter f (Fold step begin done) = Fold step' begin done
  where
    step' x a = if f a then step x a else return $ Yield x

-- | Like 'lfilter' but with a monadic predicate.
--
-- @since 0.7.0
{-# INLINABLE lfilterM #-}
lfilterM :: Monad m => (a -> m Bool) -> Fold m a r -> Fold m a r
lfilterM f (Fold step begin done) = Fold step' begin done
  where
    step' x a = do
      use <- f a
      if use then step x a else return $ Yield x

-- | Transform a fold from a pure input to a 'Maybe' input, consuming only
-- 'Just' values.
{-# INLINE lcatMaybes #-}
lcatMaybes :: Monad m => Fold m a b -> Fold m (Maybe a) b
lcatMaybes = lfilter isJust . lmap fromJust

------------------------------------------------------------------------------
-- Parsing
------------------------------------------------------------------------------

-- XXX These should become terminating folds.
--
-- | Take first 'n' elements from the stream and discard the rest.
--
-- @since 0.7.0
{-# INLINABLE ltake #-}
ltake :: Monad m => Int -> Fold m a b -> Fold m a b
ltake n (Fold step initial done) = Fold step' initial' done'
    where
    initial' = fmap (Tuple' 0) initial
    step' (Tuple' i r) a = do
        if i < n
        then do
            res <- step r a
            case res of
                Yield s -> return $ Yield $ Tuple' (i + 1) s
                Stop b -> return $ Stop b
        else Stop <$> done r
    done' (Tuple' _ r) = done r

-- | Takes elements from the input as long as the predicate succeeds.
--
-- @since 0.7.0
{-# INLINABLE ltakeWhile #-}
ltakeWhile :: Monad m => (a -> Bool) -> Fold m a b -> Fold m a b
ltakeWhile predicate (Fold step initial done) = Fold step' initial done
    where
    step' r a = do
        if predicate a
        then step r a
        else Stop <$> done r

------------------------------------------------------------------------------
-- Nesting
------------------------------------------------------------------------------
--
-- | Modify the fold such that when the fold is done, instead of returning the
-- accumulator, it returns a fold. The returned fold starts from where we left
-- i.e. it uses the last accumulator value as the initial value of the
-- accumulator. Thus we can resume the fold later and feed it more input.
--
-- >> do
-- >    more <- S.fold (FL.duplicate FL.sum) (S.enumerateFromTo 1 10)
-- >    evenMore <- S.fold (FL.duplicate more) (S.enumerateFromTo 11 20)
-- >    S.fold evenMore (S.enumerateFromTo 21 30)
-- > 465
--
-- @since 0.7.0
-- XXX Is this correct?
{-# INLINABLE duplicate #-}
duplicate :: Monad m => Fold m a b -> Fold m a (Fold m a b)
duplicate (Fold step begin done) =
    Fold step' begin (\x -> pure (Fold step (pure x) done))
    where
      step' x a = do
          res <- step x a
          case res of
              Yield s -> pure $ Yield s
              Stop _ -> pure $ Stop $ Fold step (pure x) done

-- | Run the initialization effect of a fold. The returned fold would use the
-- value returned by this effect as its initial value.
--
{-# INLINABLE initialize #-}
initialize :: Monad m => Fold m a b -> m (Fold m a b)
initialize (Fold step initial extract) = do
    i <- initial
    return $ Fold step (return i) extract

-- | Run one step of a fold and store the accumulator as an initial value in
-- the returned fold.
{-# INLINABLE runStep #-}
runStep :: Monad m => Fold m a b -> a -> m (Fold m a b)
runStep (Fold step initial extract) a = do
    i <- initial
    r <- step i a
    case r of
        Yield s -> return $ Fold step (return s) extract
        Stop b -> return $ Fold (\_ _ -> return $ Stop b) initial (\_ -> return b)


------------------------------------------------------------------------------
-- Parsing
------------------------------------------------------------------------------

-- XXX These can be expressed using foldChunks repeatedly on the input of a
-- fold.

-- | For every n input items, apply the first fold and supply the result to the
-- next fold.
--
{-# INLINE lchunksOf #-}
lchunksOf :: Monad m => Int -> Fold m a b -> Fold m b c -> Fold m a c
lchunksOf n (Fold step1 initial1 extract1) (Fold step2 initial2 extract2) =
    Fold step' initial' extract'

    where

    initial' = (Tuple3' 0) <$> initialTSM initial1 <*> initialTSM initial2
    step' (Tuple3' i r1 r2) a = do
        if i < n
        then do
            res <- stepWS step1 r1 a
            return $ Yield $ Tuple3' (i + 1) res r2
        else do
            res <- doneWS extract1 r1
            acc2 <- stepWS step2 r2 res
            case acc2 of
                Stop b -> return $ Stop b
                Yield _ -> do
                    i1 <- initial1
                    acc1 <- step1 i1 a
                    return $ Yield $ Tuple3' 1 acc1 acc2
    extract' (Tuple3' _ r1 r2) = do
        res <- doneWS extract1 r1
        acc2 <- stepWS step2 r2 res
        doneWS extract2 acc2

{-# INLINE lchunksOf2 #-}
lchunksOf2 :: Monad m => Int -> Fold m a b -> Fold2 m x b c -> Fold2 m x a c
lchunksOf2 n (Fold step1 initial1 extract1) (Fold2 step2 inject2 extract2) =
    Fold2 step' inject' extract'

    where

    inject' x = (Tuple3' 0) <$> initialTSM initial1 <*> inject2 x
    step' (Tuple3' i r1 r2) a = do
        if i < n
        then do
            res <- stepWS step1 r1 a
            return $ Tuple3' (i + 1) res r2
        else do
            res <- doneWS extract1 r1
            acc2 <- step2 r2 res

            i1 <- initial1
            acc1 <- step1 i1 a
            return $ Tuple3' 1 acc1 acc2
    extract' (Tuple3' _ r1 r2) = do
        res <- doneWS extract1 r1
        acc2 <- step2 r2 res
        extract2 acc2

-- | Group the input stream into windows of n second each and then fold each
-- group using the provided fold function.
--
-- For example, we can copy and distribute a stream to multiple folds where
-- each fold can group the input differently e.g. by one second, one minute and
-- one hour windows respectively and fold each resulting stream of folds.
--
-- @
--
-- -----Fold m a b----|-Fold n a c-|-Fold n a c-|-...-|----Fold m a c
--
-- @
-- XXX Should we check for mv2 at each step?
{-# INLINE lsessionsOf #-}
lsessionsOf :: MonadAsync m => Double -> Fold m a b -> Fold m b c -> Fold m a c
lsessionsOf n (Fold step1 initial1 extract1) (Fold step2 initial2 extract2) =
    Fold step' initial' extract'

    where

    -- XXX MVar may be expensive we need a cheaper synch mechanism here
    initial' = do
        i1 <- initialTSM initial1
        i2 <- initialTSM initial2
        mv1 <- liftIO $ newMVar i1
        mv2 <- liftIO $ newMVar (Right i2)
        t <- control $ \run ->
            mask $ \restore -> do
                tid <- forkIO $ catch (restore $ void $ run (timerThread mv1 mv2))
                                      (handleChildException mv2)
                run (return tid)
        return $ Tuple3' t (Yield mv1) mv2
    step' acc@(Tuple3' t (Yield mv1) mv2) a = do
            r1 <- liftIO $ takeMVar mv1
            res <- stepWS step1 r1 a
            liftIO $ putMVar mv1 res
            case res of
                Yield _ -> return $ Yield $ acc
                Stop _ -> return $ Yield $ Tuple3' t (Stop mv1) mv2
    step' acc@(Tuple3' _ (Stop _) _) _ = return $ Yield $ acc
    extract' (Tuple3' tid _ mv2) = do
        r2 <- liftIO $ takeMVar mv2
        liftIO $ killThread tid
        case r2 of
            Left e -> throwM e
            Right x -> doneWS extract2 x

    timerThread mv1 mv2 = do
        liftIO $ threadDelay (round $ n * 1000000)

        r1 <- liftIO $ takeMVar mv1
        i1 <- initialTSM initial1
        liftIO $ putMVar mv1 i1

        res1 <- doneWS extract1 r1
        r2 <- liftIO $ takeMVar mv2
        case r2 of
            Left _ -> liftIO $ putMVar mv2 r2
            Right x -> do
                res <- stepWS step2 x res1
                case res of
                    Yield _ -> do
                        liftIO $ putMVar mv2 $ Right res
                        timerThread mv1 mv2
                    Stop _ -> liftIO $ putMVar mv2 $ Right res

    handleChildException ::
        MVar (Either SomeException a) -> SomeException -> IO ()
    handleChildException mv2 e = do
        r2 <- takeMVar mv2
        let r = case r2 of
                    Left _ -> r2
                    Right _ -> Left e
        putMVar mv2 r
