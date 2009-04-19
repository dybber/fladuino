{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}

-- Copyright (c) 2008
--         The President and Fellows of Harvard College.
--
-- Redistribution and use in source and binary forms, with or without
-- modification, are permitted provided that the following conditions
-- are met:
-- 1. Redistributions of source code must retain the above copyright
--    notice, this list of conditions and the following disclaimer.
-- 2. Redistributions in binary form must reproduce the above copyright
--    notice, this list of conditions and the following disclaimer in the
--    documentation and/or other materials provided with the distribution.
-- 3. Neither the name of the University nor the names of its contributors
--    may be used to endorse or promote products derived from this software
--    without specific prior written permission.

-- THIS SOFTWARE IS PROVIDED BY THE UNIVERSITY AND CONTRIBUTORS ``AS IS'' AND
-- ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
-- IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
-- ARE DISCLAIMED.  IN NO EVENT SHALL THE UNIVERSITY OR CONTRIBUTORS BE LIABLE
-- FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
-- DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
-- OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
-- HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
-- LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
-- OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
-- SUCH DAMAGE.

--------------------------------------------------------------------------------
-- |
-- Module      :  Flask.Generate
-- Copyright   :  (c) Harvard University 2008
-- License     :  BSD-style
-- Maintainer  :  mainland@eecs.harvard.edu
--
--------------------------------------------------------------------------------

module Flask.Generate where

import Prelude hiding (exp)

import Control.Monad.State
import Control.Monad.Trans
import Data.IORef
import Data.List (intersperse, concat)
import qualified Data.Map as Map
import qualified Data.Set as Set
import System.Environment (getArgs)
import System.IO

import qualified Check.F
import qualified Check.Hs
import Compiler
import Control.Monad.CGen
import Data.Loc
import Data.String.Quote
import qualified Language.Hs.Syntax
import qualified Language.Hs as H
import Language.Hs.Quote
import Language.C.Syntax
import Language.C.Quote
import Text.PrettyPrint.Mainland
import qualified Transform.F.ToC as ToC
import qualified Transform.Hs.Desugar as Desugar
import qualified Transform.Hs.Rename as Rename

import Flask.Driver
import Flask.Monad
import Flask.Signals

defaultMain :: FlaskM a -> IO a
defaultMain m = do
    args       <- getArgs
    (opts, _)  <- parseOpts defaultOpts args
    writeIORef Language.Hs.Quote.quasiOpts defaultOpts
    env        <- emptyFlaskState opts
    result     <- (flip evalFlaskM) env $ do
                    addCInclude "util/delay.h"
                    addCInclude "avr/interrupt.h"
                    addCInclude "avr/io.h"
                    addCInclude "common/Flask.h"
                    addCInclude "common/event_dispatch.h"
                    fdecls <- forPrelude [] compileHs
                    modifyFlaskEnv $ \s ->
                        s { f_fdecls = f_fdecls s ++ fdecls }
                    m
    case result of
      Left err  -> fail $ show err
      Right a   -> return a
  where
    defaultOpts :: Opts
    defaultOpts = Opts  {  output    = Just "Flask"
                        ,  prelude   = Nothing
                        ,  flags     = [Opt_OptC, Opt_ImplicitPrelude]
                        }

putDoc :: MonadFlask m => FilePath -> Doc -> m ()
putDoc filepath doc = do
    h <- liftIO $ openFile filepath WriteMode
    liftIO $ hPutStr h $ pretty 80 doc
    liftIO $ hClose h

genStream :: S a -> FlaskM ()
genStream s = genStreams [unS s]

genStreams :: [FlaskM (SCode FlaskM)]
           -> FlaskM ()
genStreams ss = do
    basename <- return (maybe "Flask" id) `ap` optVal output
    scodes <- sequence ss
    timer_connections   <- getsFlaskEnv f_timer_connections
    channel_connections <- getsFlaskEnv f_channel_connections
    let scodes' = scodes ++ [scode | (_, conns) <- Map.toList timer_connections,
                                     (scode, _) <- conns]
                         ++ [scode | (_, conns) <- Map.toList channel_connections,
                                     (scode, _) <- conns]
    genHs Set.empty scodes'
    env <- getFlaskEnv
    forM_ (f_cvars env) $ \(gv, gty, ce) -> do
        Check.F.insertVar gv gty
        ToC.insertCVar gv (return ce)
    topdecls  <-  Rename.rename (f_hstopdecls env ++ f_hsdecls env) >>=
                  Desugar.desugar
    dump "hs" Opt_d_dump_hs basename "" topdecls
    live    <- getsFlaskEnv f_live_vars
    fdecls  <- Check.Hs.checkTopDecls topdecls
    fdecls' <- optimizeF basename (Set.toList live) (f_fdecls env ++ fdecls)
    ToC.transDecls fdecls'
    genC Set.empty scodes'
    finalizeTimers
    finalizeADCs
    finalizeFlows
    cdefs_toc            <- getCDefs
    cstms_toc            <- getCInitStms
    --flaskm               <- moduleName
    --flaskm_usesprovides  <- getModuleUsesProvides
    --flaskc_usesprovides  <- getConfigUsesProvides
    --flaskc_components    <- getComponents
    --flaskc_connections   <- getConnections
    filepath <- return (maybe "Flask" id) `ap` optVal output
    putDoc (filepath ++ ".pde") $ ppr [$cunit|
$edecls:cdefs_toc

void setup()
{
  $stms:cstms_toc
}

void loop()
{
  if (event_available()) 
         {
           struct event event = pop_event();
           switch (event.type)
                      {
                        case FCALL_EVENT:
                             (*event.data.fcall_event_data.func)();
                        break;
                        default:
                        break;
                      }
         }
}
|]
  where
    genHs :: Set.Set SCodeID -> [SCode FlaskM] -> FlaskM ()
    genHs _       []      = return ()
    genHs visited (scode : scodes)
        | s_id scode `Set.member` visited = genHs visited scodes
        | otherwise = do
            --liftIO $ print $ s_name scode
            connections <- getsFlaskEnv f_stream_connections
            let sconnections = [(to, v) |  (from, to, v) <- connections,
                                           s_id from == s_id scode]
            {-
            liftIO $ print $ [s_name from |  (from, to, _) <- connections,
                                             s_id to == s_id scode]
            liftIO $ print $ [s_name to |  (from, to, _) <- connections,
                                            s_id from == s_id scode]
            -}
            let es       = [H.appE (H.varE v) (H.varE x) |
                                (_, v) <- sconnections]
            let e_call   = seqsE es
            let decls    = [H.sigD [v_out] (tau H.--> unitTy),
                            H.varD  v_out [H.varP x] (H.rhsD [e_call])]
            modifyFlaskEnv $ \s -> s { f_hsdecls = f_hsdecls s ++ decls }
            (s_gen_hs scode) scode
            genHs visited' ([from |  (from, to, _) <- connections,
                                     s_id to == s_id scode] ++
                            [to |  (from, to, _) <- connections,
                                   s_id from == s_id scode] ++
                            scodes)
      where
        tau      = s_type scode
        v_out    = s_vout scode
        x        = H.var "x"
        visited' = Set.insert (s_id scode) visited

    genC :: Set.Set SCodeID -> [SCode FlaskM] -> FlaskM ()
    genC _       []      = return ()
    genC visited (scode : scodes)
        | s_id scode `Set.member` visited = genC visited scodes
        | otherwise = do
            connections <- getsFlaskEnv f_stream_connections
            (s_gen_c scode) scode
            genC visited' ([from |  (from, to, _) <- connections,
                                       s_id to == s_id scode] ++
                              [to |  (from, to, _) <- connections,
                                     s_id from == s_id scode] ++
                              scodes)
      where
        visited' = Set.insert (s_id scode) visited

    seqE :: H.Exp -> H.Exp -> H.Exp
    seqE e1 e2 = H.appE (H.appE (H.varE seqV) e1) e2

    seqsE :: [H.Exp] -> H.Exp
    seqsE es  = foldr seqE unitE es

    seqV :: H.Var
    seqV = H.var "seq"

    unitE :: H.Exp
    unitE = H.conE (H.TupleCon 0)

finalizeTimers :: forall m . MonadFlask m
               => m ()
finalizeTimers = do
    timers <- getsFlaskEnv $ \s -> Map.toList (f_timers s)
    when (timers /= []) $ do 
                   addCInclude "common/timersupport.h"
                   addCInitStm [$cstm|SetupTimer2(OVERFLOWS_PER_SECOND);|]
    counterCode <- forM timers $ \(period, timerC) ->
        finalizeTimer period timerC
    let (funcs, counterDefs, counterStms) = unzip3 counterCode
    let stms = concat counterStms
    mapM_ addCFundef funcs
    addCFundef [$cedecl|
void timer2_interrupt_handler (void)
{
  $decls:counterDefs
  $stms:stms
}
|]
  where
    finalizeTimer :: Int -> String -> m (Definition, InitGroup, [Stm])
    finalizeTimer period _ = do
        let c_period = toInteger period
        vs <- getsFlaskEnv $ \s ->
            Map.findWithDefault [] period (f_timer_connections s)
        stms <- forM vs $ \(_, v) -> do
                e <- hcall v $ ToC.CLowered unitGTy [$cexp|NULL|]
                return $ Exp (Just e) internalLoc
        return ([$cedecl|void $id:timerCP (void) { $stms:stms } |],
                [$cdecl|static int $id:counterCP = 0;|], 
                [[$cstm|$id:counterCP = $id:counterCP + 1;|],
                 [$cstm|if ( $id:counterCP >= (OVERFLOWS_PER_SECOND/1000* $int:c_period ))
                           {
                             queue_funcall(&$id:timerCP);
                             $id:counterCP = 0;
                           }|]])
      where
        timerCP = "timer" ++ show period
        counterCP = timerCP ++ "_counter"

finalizeADCs :: MonadFlask m => m ()
finalizeADCs = do
    adcs <- getsFlaskEnv f_adcs
    when (adcs > 0) $ do
        adc_stms <-
            forM [0..adcs - 1] $ \i -> do
                let c_i = toInteger i
                e <- getsFlaskEnv $ \s -> f_adc_getdata s Map.! i
                return [$cstm|
if ((adc_pending & 1 << $int:c_i) != 0) {
    $exp:e;
    return;
}
|]
        addCDecldef [$cedecl|typename uint16_t adc_val;|]
        addCDecldef [$cedecl|typename uint32_t adc_pending;|]
        addCInitStm [$cstm|adc_pending = 0;|]
        addCFundef [$cedecl|
void adc_process_pending()
{
  $stms:adc_stms
}
|]

finalizeFlows ::  FlaskM ()
finalizeFlows = do
    receiving <- getsFlaskEnv $ \s -> Map.toList (f_channel_receiving s)
    {-forM receiving $ \(chan, activity) ->
        case activity of
          Active   -> addCInitStm [$cstm|call Flow.subscribe($int:chan, TRUE);|]
          Passive  -> addCInitStm [$cstm|call Flow.subscribe($int:chan, FALSE);|]-}

    sending <- getsFlaskEnv $ \s -> Map.toList (f_channel_sending s)
    {-forM sending $ \(chan, activity) ->
        case activity of
          Active   -> addCInitStm [$cstm|call Flow.publish($int:chan, TRUE);|]
          Passive  -> addCInitStm [$cstm|call Flow.publish($int:chan, FALSE);|]-}

    connections <- getsFlaskEnv $ \s -> Map.toList (f_channel_connections s)
    return ()
    --handlers    <- forM connections $ \(chan, vs) -> finalizeChannel chan vs
    --let switch_stms = intersperse [$cstm|break;|] handlers
    --usesProvides True [$ncusesprovides|uses interface Flow;|]
    {-addCVardef [$cedecl|
event void Flow.receive(typename flowid_t flow_id, void *data, typename size_t size)
{
    switch (flow_id) {
        $stms:switch_stms
    }
}
|]-}
  where
    {-
    finalizeChannel :: Integer -> [(SCode FlaskM, H.Var)] -> FlaskM Stm
    finalizeChannel chan vs = do
        tau  <- getsFlaskEnv $ \s -> f_channel_types s Map.! chan
        cty  <- toC tau
        stms <- forM vs $ \(_, v) -> do
                e <- hcall v $ ToC.CLowered tau [$cexp|temp|]
                return $ Exp (Just e) internalLoc
        return [$cstm|
case $int:chan:
    if (size == sizeof($ty:cty)) {
        $ty:cty temp;
        memcpy(&temp, data, sizeof(temp));
        $stms:stms;
    }
|]
-}