{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE NoMonomorphismRestriction #-}

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
-- Module      :  Fladuino.Device
-- Copyright   :  (c) Harvard University 2008
-- License     :  BSD-style
-- Maintainer  :  athas@sigkill.dk
--
--------------------------------------------------------------------------------

module Fladuino.Device where

import Prelude hiding (exp)

import Control.Monad.State
import Control.Monad.Trans
import Data.IORef
import Data.List (intersperse, concat)
import Data.Maybe
import qualified Data.Map as Map
import qualified Data.Set as Set
import System.IO

import qualified Check.F
import qualified Check.Hs
import Compiler
import Control.Monad.CGen
import Data.Loc
import Data.Name
import Data.List
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

import Fladuino.Driver
import Fladuino.Monad
import Fladuino.Signals
import Fladuino.Reify

import Fladuino.LiftN

data PinDecl = PinDecl Pin [Capability]

data MonadFladuino m => Platform m = Platform
    { p_pins :: [PinDecl]
    , p_pinmap :: Pin -> Integer
    , p_capabilities :: [Capability]
    , p_base_setup :: m ()
    , p_timerid :: Integer }

data MonadFladuino m => PConf m = PConf (Platform m) [Usage] [m ()]

startConf :: MonadFladuino m => Platform m -> m (PConf m)
startConf p = return (PConf p [] [p_base_setup p])

supports :: MonadFladuino m => PConf m -> Usage -> Bool
supports (PConf p _ _) (DPinUsage pin caps _) = isJust $ find f (p_pins p)
    where f (PinDecl pin' caps') = (DPin pin) == pin' && null (caps \\ caps')
supports (PConf p _ _) (APinUsage pin caps) = isJust $ find f (p_pins p)
    where f (PinDecl pin' caps') = (APin pin) == pin' && null (caps \\ caps')

conflicts :: MonadFladuino m => PConf m -> Usage -> Bool
conflicts (PConf _ us _) (DPinUsage pin _ _) = isJust $ find f us
    where f (DPinUsage pin' _ _) = pin == pin'
          f _ = False
conflicts (PConf _ us _) (APinUsage pin _) = isJust $ find f us
    where f (APinUsage pin' _) = pin == pin'
          f _ = False
conflicts _ _ = False

extendConfiguration :: MonadFladuino m => PConf m -> [Usage] -> m (PConf m)
extendConfiguration pc@(PConf p _ _) (CapabilityRequired cap : us)
    | cap `elem` p_capabilities p = extendConfiguration pc us
    | otherwise = fail $ "Selected platform does not supply required '" ++ cap ++ " capability"
extendConfiguration pc@(PConf p usages ss) (u@(DPinUsage pin caps _) : us)
    | pc `conflicts` u = fail $ "Digital pin " ++ show pin ++ " reserved twice"
    | pc `supports` u = extendConfiguration (PConf p (u : usages) ss) us
    | otherwise = fail $ "Cannot provide digital pin " ++ show pin ++ " with capabilities " ++ show caps
extendConfiguration pc@(PConf p usages ss) (u@(APinUsage pin caps) : us)
    | pc `conflicts` u = fail $ "Analog pin " ++ show pin ++ " reserved twice"
    | pc `supports` u = extendConfiguration (PConf p (u : usages) ss) us
    | otherwise = fail $ "Cannot provide analog pin " ++ show pin ++ " with capabilities " ++ show caps
extendConfiguration pc [] = return pc

configureDevice :: (MonadFladuino m) => PConf m -> DRef -> m (PConf m)
configureDevice pc (DRef d) = do (PConf p u s) <- extendConfiguration pc (usages d)
                                 return (PConf p u (setupDevice d : s))

statevar :: Device d => MonadFladuino m => d -> String -> m String
statevar d s = do
  devices <- getsFladuinoEnv f_devices
  case findIndex (\(DRef d2) -> uniqueId d2 == uniqueId d) devices of
    Just n -> return $ "device_" ++ (uniqueId d) ++ s
    Nothing -> return $ error $ "Unknown device " ++ uniqueId d ++ " encountered."
                      
class (Eq e, Show e, Reify t) => Event e t | e -> t where
    interruptPins :: e -> [Pin]
    setupEvent :: e -> FladuinoM ERep

eventValueType :: forall e t. (Event e t) => e -> H.Type
eventValueType _ = reify (undefined :: t)

mkEvent :: forall e t. (Event e t) => e -> Maybe H.Var -> Maybe H.Var -> ERep
mkEvent e val pred = ERep { e_value = val
                          , e_predicate = pred
                          , e_id = show e
                          , e_interrupts = interruptPins e
                          , e_type = reify (undefined :: t) }

lookupEvent :: forall t e m. (Event e t, MonadFladuino m) => e -> m (Maybe ERep)
lookupEvent event = do 
  events <- getsFladuinoEnv f_events 
  case find (\(ERep { e_id = id}) -> show event == id) events of
    Just erep  -> return $ Just erep
    Nothing -> return Nothing

connectEvent :: forall t e. (Event e t) => e -> SCode FladuinoM -> H.Var -> FladuinoM ()
connectEvent event stream v = do
  liveVar v
  eref <- lookupEvent event
  case eref of
    Just eref -> modifyFladuinoEnv $ \s ->
                              s { f_event_connections = update (eref, (stream, v)) (f_event_connections s) }
    Nothing -> do addEvent event
                  connectEvent event stream v
    where
      update :: Eq a => (a, b) -> [(a,[b])] -> [(a,[b])]
      update (key, value) [] = [(key, [value])]
      update (key, value) ((key2, values):xs)
          | (key == key2) = (key, value:values):xs
          | otherwise = (key2, values) : update (key, value) xs

      addEvent event = do erep <- setupEvent event
                          let erep' = erep { e_type = eventValueType event }
                          modifyFladuinoEnv $ \s ->
                              s { f_events = erep' : (f_events s) }
                          liveVar v

onEvent :: forall e t. (Reify t, Event e t) => e -> S t
onEvent event = S $ do
    addStream  "onEvent"
               tau_t
               (OnEvent $ show event)
               gen
               (const (return ())) $ \this -> do
    connectEvent event this (varIn this "")
  where
    tau_t :: H.Type
    tau_t = reify (undefined :: t)

    gen :: SCode m -> FladuinoM ()
    gen this = do
        addDecls [$decls|$var:v_in :: $ty:tau_t -> ()|]
        addDecls [$decls|$var:v_in x = $var:v_out x|]
      where
        v_in  = varIn this ""
        v_out = s_vout this

postThenWait :: forall a eta e t. (Reify a, Reify t, LiftN eta (() -> ()), Event e t)
                => eta -> e -> S a -> S t
postThenWait poster event from = S $ do
    nposter <- unN $ (liftN poster :: N (() -> ()))
    sfrom   <- unS from
    addStream  "postThenWait"
               unitTy
               (Poster sfrom $ show event)
               genHs
               (genC nposter) $ \this -> do 
      connect sfrom this tau_a (varIn this "")
      connectEvent event this (varIn this "receiver")
    where
      tau_a = reify (undefined :: a)
      tau_t = reify (undefined :: t)

      genHs this = do
        addCImport c_v_in   [$ty|$ty:tau_a -> ()|] [$cexp|$id:c_v_in|]
        addCImport c_v_recv [$ty|$ty:tau_t -> ()|] [$cexp|$id:c_v_recv|]
          where
            v_in     = varIn this ""
            c_v_in   = show v_in
            v_recv   = varIn this "receiver"
            c_v_recv = show v_recv

      genC :: NCode -> SCode m -> FladuinoM ()
      genC nf this = do
        tauf_a     <- toF tau_a
        (a_params, a_params_ce) <- ToC.flattenParams tauf_a
        post       <- hcall v_f $ ToC.CUnboxedData unitGTy []
        tauf_t     <- toF tau_t
        (t_params, t_params_ce) <- ToC.flattenParams tauf_t
        e_out      <- hcall v_out $ ToC.CUnboxedData tauf_t [t_params_ce]
        addCDecldef [$cedecl|unsigned char $id:enabled = 0;|]
        addCFundef [$cedecl|
void $id:c_v_in($params:a_params)
{
  $exp:post;
  $id:enabled = 1;
}
|]
        addCFundef [$cedecl|
void $id:c_v_recv($params:t_params)
{
  if ($id:enabled) {
    $id:enabled = 0;
    $exp:e_out;
  }
}
|]
        where
          v_in     = varIn this ""
          c_v_in   = show v_in
          v_recv   = varIn this "receiver"
          c_v_recv = show v_recv
          v_f      = n_var nf
          enabled  = ident this "enabled"
          v_out    = s_vout this

delayUntilEvent :: forall a e t. (Reify a, Event e t) => e -> S a -> S t
delayUntilEvent = postThenWait [$exp|\_ -> ()|]
