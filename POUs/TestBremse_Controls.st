(* ================================================================================
   TestBremse_Controls   (PROGRAM / PRG)
   CODESYS 3.5.18.4 - Structured Text

   SCOPO
   -----
   Gestione guidata e interbloccata dei due freni della winda in Service Mode:
     1) Controllo lueftspalt (traferro) -> si apre UN solo freno, l'altro tiene
     2) Bremstest (prova freni)         -> coppia rampata contro il freno chiuso
                                           con sorveglianza dello slittamento

   Sigle dei freni (mantenute come nell'impianto):
     SB = Standbremse    = freno di stazionamento
     BB = Betriebsbremse = freno di servizio

   REGOLE BASE (richiesta della direzione tecnica)
   -----------------------------------------------
   * Utilizzabile solo in Service Mode (chiave fisica) e da livello utente 2
   * Il Notaus resta sempre attivo ed e' condizione di consenso
   * Puo' essere aperto un solo freno per volta
   * Il freno aperto va richiuso MANUALMENTE prima di poter aprire l'altro
     (interblocco iBrakeOpenLatch)
   * Giri e coppia sono sorvegliati in permanenza: in caso di movimento o di
     coppia non ammessa i setpoint vengono azzerati e i freni si chiudono

   ATTENZIONE - SICUREZZA
   ----------------------
   Questa sequenza e' l'interblocco FUNZIONALE nel PLC standard.
   L'interblocco di sicurezza vero (un solo freno aperto, Notaus, sorveglianza
   di fermo macchina e dei giri, limitazione sicura della coppia) va realizzato
   e valutato nella sicurezza Pilz.
   Questo PLC non deve bypassare nessuna funzione di sicurezza.

   INTEGRAZIONE
   ------------
   * Richiamare il PRG nel task DOPO la normale gestione winda, cosi' i setpoint
     forzati qui (0 / limitati) sono gli ultimi scritti.
   * Il vecchio blocco
         IF g_io.Standbremsentest THEN
             IO_Hauptinverter.Solldrehmoment := DMStandbremsentest; ...
     va rimosso: i setpoint ora li scrive solo questo PRG.
   * g_IO.Standbremsentest diventa puro bit di bypass per la catena di consenso
     dei freni (durante la prova la SB e' CHIUSA ma l'azionamento deve dare coppia).
   * Per la prova del freno di servizio aggiungere nella GVL
         Betriebsbremsentest : BOOL;
     ed estendere la catena di consenso:
         g_IO.AlleBremsenoffen := (g_IO.SBoffen OR g_IO.Standbremsentest)
                              AND (g_IO.BBoffen OR g_IO.Betriebsbremsentest);
   * Le righe marcate TODO sono le interfacce verso l'impianto: vanno adattate
     una sola volta ai nomi/tipi reali del progetto.
   ================================================================================ *)

PROGRAM TestBremse_Controls
VAR CONSTANT
    (* ---- Passi della sequenza ---- *)
    STEP_LOCKED             : INT := 0;    (* modo freni non selezionato            *)
    STEP_READY              : INT := 10;   (* modo attivo, entrambi i freni chiusi  *)
    STEP_OPENING            : INT := 20;   (* comando di apertura, attesa feedback  *)
    STEP_OPEN               : INT := 30;   (* un freno aperto (misura traferro)     *)
    STEP_TEST_RAMP          : INT := 40;   (* salita a rampa della coppia           *)
    STEP_TEST_HOLD          : INT := 50;   (* mantenimento coppia, verifica slittam.*)
    STEP_TEST_RAMPDOWN      : INT := 60;   (* discesa della coppia                  *)
    STEP_CLOSING            : INT := 70;   (* chiusura manuale (obbligatoria)       *)
    STEP_FAULT              : INT := 90;   (* anomalia, serve il reset              *)

    (* ---- Selezione del freno ---- *)
    BRAKE_NONE              : INT := 0;
    BRAKE_SB                : INT := 1;    (* Standbremse    - freno di stazionamento *)
    BRAKE_BB                : INT := 2;    (* Betriebsbremse - freno di servizio      *)

    (* ---- Selezione della funzione ---- *)
    MODE_NONE               : INT := 0;
    MODE_AIRGAP             : INT := 1;    (* solo apertura, NESSUNA coppia           *)
    MODE_BRAKETEST          : INT := 2;    (* coppia contro il freno chiuso           *)

    (* ---- Codici di anomalia ---- *)
    ERR_NONE                : INT := 0;
    ERR_SERVICEMODE         : INT := 1;    (* Service Mode caduto                     *)
    ERR_USERLEVEL           : INT := 2;    (* livello utente < 2                      *)
    ERR_ESTOP               : INT := 3;    (* Notaus / Pilz non ok                    *)
    ERR_BOTH_OPEN           : INT := 4;    (* entrambi i freni aperti insieme         *)
    ERR_MOVEMENT            : INT := 5;    (* giri fuori finestra ammessa             *)
    ERR_TORQUE              : INT := 6;    (* coppia reale non ammessa                *)
    ERR_FB_OPEN             : INT := 7;    (* manca il feedback "aperto"              *)
    ERR_FB_CLOSED           : INT := 8;    (* manca il feedback "chiuso"              *)
    ERR_TEST_FAILED         : INT := 9;    (* il freno non tiene la coppia di prova   *)
    ERR_OPEN_TIMEOUT        : INT := 10;   (* superato il tempo massimo di apertura   *)
    ERR_OPMODE              : INT := 11;   (* messa in servizio / simulazione attiva  *)
    ERR_DRIVE               : INT := 12;   (* inverter non pronto / in blocco         *)

    MIN_USERLEVEL           : INT := 2;    (* richiesta: livello utente 2             *)
    CYCLE_MS                : REAL := 10.0;(* TODO: allineare al ciclo del task       *)
END_VAR

VAR
    (* ============================================================
       1) COMANDI DA DISPLAY
          La visu scrive direttamente su queste variabili.
          Configurare i pulsanti come "variabile a impulso" (FALSE->TRUE):
          la valutazione avviene sul fronte di salita.
          Restano in piedi anche i blocchi gia' presenti nella visu:
          ((IOPilzWinde.K_NAok_VZ) AND (g_IO.ServiceMode)
           AND (CurrentUserLevel>=2)) = FALSE
       ============================================================ *)
    xCmdModeOn              : BOOL;   (* selezione del modo freni                  *)
    xCmdModeOff             : BOOL;   (* uscita dal modo freni                     *)
    xCmdSelectSB            : BOOL;   (* seleziona il freno di stazionamento       *)
    xCmdSelectBB            : BOOL;   (* seleziona il freno di servizio            *)
    xCmdSelectAirgap        : BOOL;   (* funzione controllo traferro               *)
    xCmdSelectBrakeTest     : BOOL;   (* funzione prova freni                      *)
    xAckHazard              : BOOL;   (* conferma: pericolo schiacciamento / winda scarica *)
    xCmdOpen                : BOOL;   (* apri il freno selezionato                 *)
    xCmdClose               : BOOL;   (* chiudi manualmente il freno (obbligatorio)*)
    xCmdTestStart           : BOOL;   (* avvia la prova freni                      *)
    xCmdTestStop            : BOOL;   (* interrompi la prova freni                 *)
    xCmdReset               : BOOL;   (* reset anomalia                            *)
    iTestDirection          : INT := 1; (* +1 = senso di tiro, -1 = senso opposto  *)

    (* ============================================================
       2) PARAMETRI (regolabili online, volendo da tenere PERSISTENT)
          Tutti i valori vanno tarati sull'impianto specifico.
       ============================================================ *)
    rRpmStandstill          : REAL := 2.0;    (* giri/min: finestra di fermo per il consenso *)
    rRpmTripOpen            : REAL := 5.0;    (* giri/min: movimento a freno aperto -> stop  *)
    rRpmSlipLimit           : REAL := 3.0;    (* giri/min: slittamento ammesso nella prova   *)
    rRpmTestSetpoint        : REAL := 5.0;    (* giri/min: setpoint giri durante la prova    *)
    rSlipLimitRev           : REAL := 0.05;   (* giri: rotazione ammessa nella prova         *)
    rTorqueStandstill       : REAL := 5.0;    (* coppia reale ammessa prima di aprire        *)
    rTorqueTestSB           : REAL := 0.0;    (* coppia di prova SB  -> da parametrizzare    *)
    rTorqueTestBB           : REAL := 0.0;    (* coppia di prova BB  -> da parametrizzare    *)
    rTorqueMax              : REAL := 0.0;    (* limite superiore duro -> da parametrizzare  *)
    rTorqueRampPerSec       : REAL := 10.0;   (* incremento di coppia al secondo             *)
    tTestHoldTime           : TIME := T#5S;   (* tempo di mantenimento della coppia di prova *)
    tMonOpen                : TIME := T#3S;   (* attesa massima del feedback "aperto"        *)
    tMonClose               : TIME := T#3S;   (* attesa massima del feedback "chiuso"        *)
    tMaxOpen                : TIME := T#30M;  (* tempo massimo con un freno aperto           *)
    tAckValid               : TIME := T#60S;  (* validita' della conferma del pericolo       *)
    tMonTorqueFree          : TIME := T#1S;   (* ritardo sorveglianza "coppia libera"        *)
    xAutoCloseOnTimeout     : BOOL := FALSE;  (* TRUE: chiude d'ufficio dopo tMaxOpen        *)

    (* ============================================================
       3) VALORI REALI / FEEDBACK (immagine, assegnata nella sezione A)
       ============================================================ *)
    rActRpm                 : REAL;   (* giri reali                                *)
    rActTorque              : REAL;   (* coppia reale                              *)
    iUserLevel              : INT;    (* livello utente attuale                    *)
    xSB_IsOpen              : BOOL;   (* feedback: SB aperto                       *)
    xSB_IsClosed            : BOOL;   (* feedback: SB chiuso                       *)
    xBB_IsOpen              : BOOL;   (* feedback: BB aperto                       *)
    xBB_IsClosed            : BOOL;   (* feedback: BB chiuso                       *)
    xServiceMode            : BOOL;   (* chiave di Service Mode                    *)
    xEStopOK                : BOOL;   (* catena Notaus in ordine (Pilz)            *)
    xDriveReady             : BOOL;   (* inverter pronto, senza blocchi            *)
    xOpModeBlock            : BOOL;   (* messa in servizio / simulazione / marcia   *)

    (* ============================================================
       4) CONSENSI E STATO
       ============================================================ *)
    xEn_ServiceMode         : BOOL;
    xEn_UserLevel           : BOOL;
    xEn_EStop               : BOOL;
    xEn_OpMode              : BOOL;
    xEn_Drive               : BOOL;
    xEn_Standstill          : BOOL;
    xEn_TorqueFree          : BOOL;
    xEn_Overall             : BOOL;   (* condizione permanente durante il modo     *)
    xEn_Open                : BOOL;   (* condizione di transizione "apri"          *)
    xEn_TestStart           : BOOL;   (* condizione di transizione "avvia prova"   *)

    (* ---- Stato principale / uscite del PRG ---- *)
    xBrakeModeActive        : BOOL;   (* modo freni attivo -> blocca il normale funzionamento *)
    xBrakeIsOpen            : BOOL;   (* un freno risulta aperto                   *)
    xTestRunning            : BOOL;   (* prova freni in corso                      *)
    xTestPassed             : BOOL;   (* esito prova: i.O.                         *)
    xTestFailed             : BOOL;   (* esito prova: n.i.O.                       *)
    xManualCloseRequired    : BOOL;   (* interblocco attivo fino alla chiusura manuale *)
    xOutSB_Open             : BOOL;   (* comando di apertura SB                    *)
    xOutBB_Open             : BOOL;   (* comando di apertura BB                    *)
    xBypassSB               : BOOL;   (* -> g_IO.Standbremsentest                  *)
    xBypassBB               : BOOL;   (* -> g_IO.Betriebsbremsentest (nuova in GVL)*)
    xDriveEnableTest        : BOOL;   (* consenso inverter solo durante la prova   *)

    iStep                   : INT := 0;  (* passo attuale della sequenza           *)
    iBrakeSelected          : INT := 0;  (* freno selezionato dall'operatore        *)
    iBrakeOpenLatch         : INT := 0;  (* INTERBLOCCO: quale freno e'/era aperto  *)
    iMode                   : INT := 0;  (* funzione selezionata                    *)
    iFaultCode              : INT := 0;  (* codice di anomalia attuale              *)
    iLastTestResult         : INT := 0;  (* 0 = nessuno, 1 = i.O., 2 = n.i.O.       *)

    (* ---- Setpoint verso l'azionamento ---- *)
    rTorqueSet              : REAL;   (* coppia di riferimento, rampata            *)
    rTorqueTarget           : REAL;   (* coppia di prova del freno selezionato     *)
    rRpmSet                 : REAL;   (* setpoint giri                             *)
    rRpmLimit               : REAL;   (* limite giri applicato al setpoint         *)
    rDirection              : REAL := 1.0; (* +1.0 / -1.0 ricavato da iTestDirection *)

    (* ---- Misure della prova freni ---- *)
    rSlipRev                : REAL;   (* rotazione integrata durante la prova      *)
    rMaxRpmInTest           : REAL;   (* picco di giri durante la prova            *)
    rTorqueReachedInTest    : REAL;   (* coppia reale massima raggiunta            *)

    (* ---- Rilevamento fronti ---- *)
    rtrModeOn               : R_TRIG;
    rtrModeOff              : R_TRIG;
    rtrSelSB                : R_TRIG;
    rtrSelBB                : R_TRIG;
    rtrSelAirgap            : R_TRIG;
    rtrSelBrakeTest         : R_TRIG;
    rtrOpen                 : R_TRIG;
    rtrClose                : R_TRIG;
    rtrTestStart            : R_TRIG;
    rtrTestStop             : R_TRIG;
    rtrReset                : R_TRIG;

    (* ---- Temporizzatori ---- *)
    tonOpen                 : TON;    (* sorveglianza feedback "aperto"            *)
    tonClose                : TON;    (* sorveglianza feedback "chiuso"            *)
    tonHold                 : TON;    (* tempo di mantenimento della prova         *)
    tonMaxOpen              : TON;    (* tempo massimo con freno aperto            *)
    tonAck                  : TON;    (* scadenza della conferma del pericolo      *)
    tonTorqueFree           : TON;    (* sorveglianza ritardata "coppia libera"    *)

    (* ---- Diagnostica per la visu ---- *)
    sStepText               : STRING(80);  (* testo di stato (in tedesco, per l'operatore) *)
    sFaultText              : STRING(80);  (* testo di anomalia (in tedesco)               *)
    xWarnOpenTime           : BOOL;        (* avviso: freno aperto da troppo tempo         *)
END_VAR

(* ================================================================================
   A) INTERFACCIA VERSO L'IMPIANTO - lettura dei valori reali
      TODO: verificare una sola volta nomi e tipi rispetto al progetto
   ================================================================================ *)
xServiceMode := g_IO.ServiceMode;
xEStopOK     := IOPilzWinde.K_NAok_VZ;                   (* catena Notaus ok, ritardata *)
iUserLevel   := CurrentUserLevel;                        (*TODO*) (* verificare la sorgente del livello utente *)

xSB_IsOpen   := g_IO.SBoffen;
xSB_IsClosed := NOT g_IO.SBoffen;                        (*TODO*) (* se esiste un feedback "SBzu" dedicato, usarlo qui *)
xBB_IsOpen   := g_IO.BBoffen;
xBB_IsClosed := g_IO.BBzu;

rActRpm      := INT_TO_REAL(IO_Hauptinverter.IstRpmInverter);   (*TODO*) (* nome/tipo del valore reale giri  *)
rActTorque   := IO_Hauptinverter.Istdrehmoment;                 (*TODO*) (* nome/tipo del valore reale coppia *)
xDriveReady  := IO_Hauptinverter.Bereit;                        (*TODO*) (* segnale di pronto / blocco        *)

(* Modi di funzionamento che escludono il modo freni *)
xOpModeBlock := App_Winde.inbetriebnahme;                (*TODO*) (* eventualmente OR simbremsen OR comando di marcia *)

(* ================================================================================
   B) CONSENSI
      xEn_Overall e' una condizione PERMANENTE: se cade si interrompe subito,
      i comandi di apertura vengono tolti (i freni si chiudono a molla) e il
      setpoint di coppia va a zero.
   ================================================================================ *)
xEn_ServiceMode := xServiceMode;
xEn_UserLevel   := (iUserLevel >= MIN_USERLEVEL);        (* eventualmente AND PLC_PRG.userlevel3 *)
xEn_EStop       := xEStopOK;
xEn_OpMode      := NOT xOpModeBlock;
xEn_Drive       := xDriveReady;
xEn_Standstill  := (ABS(rActRpm) <= rRpmStandstill);
xEn_TorqueFree  := (ABS(rActTorque) <= rTorqueStandstill);

xEn_Overall := xEn_ServiceMode
           AND xEn_UserLevel
           AND xEn_EStop
           AND xEn_OpMode
           AND xEn_Drive;

(* La conferma del pericolo scade: prima di ogni apertura va ridata coscientemente *)
tonAck(IN := xAckHazard, PT := tAckValid);
IF tonAck.Q OR NOT xBrakeModeActive THEN
    xAckHazard := FALSE;
END_IF

(* Condizioni di transizione, usate anche come enable dei pulsanti in visu *)
xEn_Open := xEn_Overall
        AND xEn_Standstill
        AND xEn_TorqueFree
        AND xAckHazard
        AND (iBrakeOpenLatch = BRAKE_NONE)          (* punto chiave: un solo freno aperto *)
        AND (iBrakeSelected <> BRAKE_NONE)
        AND (iMode <> MODE_NONE)
        AND xSB_IsClosed AND xBB_IsClosed
        AND (iStep = STEP_READY);

xEn_TestStart := xEn_Overall
             AND (iStep = STEP_OPEN)
             AND (iMode = MODE_BRAKETEST)
             AND xEn_Standstill
             AND (rTorqueTarget > 0.0);

(* ================================================================================
   C) VALUTAZIONE DEI COMANDI SUL FRONTE DI SALITA
   ================================================================================ *)
rtrModeOn(CLK := xCmdModeOn);
rtrModeOff(CLK := xCmdModeOff);
rtrSelSB(CLK := xCmdSelectSB);
rtrSelBB(CLK := xCmdSelectBB);
rtrSelAirgap(CLK := xCmdSelectAirgap);
rtrSelBrakeTest(CLK := xCmdSelectBrakeTest);
rtrOpen(CLK := xCmdOpen);
rtrClose(CLK := xCmdClose);
rtrTestStart(CLK := xCmdTestStart);
rtrTestStop(CLK := xCmdTestStop);
rtrReset(CLK := xCmdReset);

(* La selezione di freno e funzione e' possibile solo con tutto chiuso e nessuna prova in corso *)
IF (iStep = STEP_READY) AND (iBrakeOpenLatch = BRAKE_NONE) THEN
    IF rtrSelSB.Q THEN
        iBrakeSelected  := BRAKE_SB;
        iLastTestResult := 0;
    END_IF
    IF rtrSelBB.Q THEN
        iBrakeSelected  := BRAKE_BB;
        iLastTestResult := 0;
    END_IF
    IF rtrSelAirgap.Q THEN
        iMode := MODE_AIRGAP;
    END_IF
    IF rtrSelBrakeTest.Q THEN
        iMode := MODE_BRAKETEST;
    END_IF
END_IF

(* Normalizzazione del senso di prova a +1 / -1 *)
IF iTestDirection >= 0 THEN
    rDirection := 1.0;
ELSE
    rDirection := -1.0;
END_IF

(* Coppia di prova del freno selezionato: si prova sempre il freno CHIUSO,
   quello che viene aperto e' l'altro.                                        *)
CASE iBrakeSelected OF
    BRAKE_SB:  rTorqueTarget := LIMIT(0.0, rTorqueTestSB, rTorqueMax);
    BRAKE_BB:  rTorqueTarget := LIMIT(0.0, rTorqueTestBB, rTorqueMax);
ELSE
    rTorqueTarget := 0.0;
END_CASE

(* ================================================================================
   D) SORVEGLIANZE DURE - valgono in ogni passo del modo freni
   ================================================================================ *)
IF xBrakeModeActive THEN

    (* D1 - caduta di uno dei consensi di base *)
    IF NOT xEn_Overall THEN
        IF NOT xEn_EStop THEN
            iFaultCode := ERR_ESTOP;
        ELSIF NOT xEn_ServiceMode THEN
            iFaultCode := ERR_SERVICEMODE;
        ELSIF NOT xEn_UserLevel THEN
            iFaultCode := ERR_USERLEVEL;
        ELSIF NOT xEn_OpMode THEN
            iFaultCode := ERR_OPMODE;
        ELSE
            iFaultCode := ERR_DRIVE;
        END_IF
        iStep := STEP_FAULT;
    END_IF

    (* D2 - mai entrambi i freni aperti nello stesso momento *)
    IF xSB_IsOpen AND xBB_IsOpen THEN
        iFaultCode := ERR_BOTH_OPEN;
        iStep      := STEP_FAULT;
    END_IF

    (* D3 - movimento a freno aperto fuori dalla prova freni *)
    IF (iStep = STEP_OPENING) OR (iStep = STEP_OPEN) OR (iStep = STEP_CLOSING) THEN
        IF ABS(rActRpm) > rRpmTripOpen THEN
            iFaultCode := ERR_MOVEMENT;
            iStep      := STEP_FAULT;
        END_IF
    END_IF

    (* D4 - sorveglianza della coppia
       - durante la prova: la coppia reale non deve superare il limite massimo
       - fuori dalla prova: con un freno aperto l'azionamento deve essere scarico *)
    IF xTestRunning THEN
        IF (rTorqueMax > 0.0) AND (ABS(rActTorque) > rTorqueMax * 1.1) THEN
            rTorqueSet := 0.0;
            iFaultCode := ERR_TORQUE;
            iStep      := STEP_FAULT;
        END_IF
    END_IF

    (* Coppia libera a freno aperto senza prova in corso: leggermente ritardata,
       cosi' la discesa di coppia dopo una prova non viene letta come anomalia *)
    tonTorqueFree(IN := xBrakeIsOpen AND NOT xTestRunning AND NOT xEn_TorqueFree,
                  PT := tMonTorqueFree);
    IF tonTorqueFree.Q THEN
        rTorqueSet := 0.0;
        iFaultCode := ERR_TORQUE;
        iStep      := STEP_FAULT;
    END_IF

    (* D5 - sorveglianza del tempo massimo di apertura *)
    tonMaxOpen(IN := xBrakeIsOpen, PT := tMaxOpen);
    xWarnOpenTime := tonMaxOpen.Q;
    IF tonMaxOpen.Q AND xAutoCloseOnTimeout AND (iStep = STEP_OPEN) THEN
        iFaultCode := ERR_OPEN_TIMEOUT;
        iStep      := STEP_CLOSING;
    END_IF
ELSE
    tonMaxOpen(IN := FALSE, PT := tMaxOpen);
    tonTorqueFree(IN := FALSE, PT := tMonTorqueFree);
    xWarnOpenTime := FALSE;
END_IF

(* ================================================================================
   E) SEQUENZA A PASSI
      I temporizzatori sono richiamati ciclicamente e indipendentemente dal passo
      attivo: cosi' si azzerano in modo sicuro appena si lascia il passo, anche
      quando l'uscita avviene per un'interruzione della sezione D.
   ================================================================================ *)
tonOpen(IN := (iStep = STEP_OPENING),   PT := tMonOpen);
tonClose(IN := (iStep = STEP_CLOSING),  PT := tMonClose);
tonHold(IN := (iStep = STEP_TEST_HOLD), PT := tTestHoldTime);

CASE iStep OF

(* ---------------------------------------------------------------- *)
STEP_LOCKED:
    xBrakeModeActive := FALSE;
    xTestRunning     := FALSE;
    xOutSB_Open      := FALSE;
    xOutBB_Open      := FALSE;
    xBypassSB        := FALSE;
    xBypassBB        := FALSE;
    rTorqueSet       := 0.0;
    rRpmSet          := 0.0;
    iMode            := MODE_NONE;
    iBrakeSelected   := BRAKE_NONE;
    iFaultCode       := ERR_NONE;

    (* L'interblocco si sblocca solo con entrambi i freni sicuramente chiusi *)
    IF xSB_IsClosed AND xBB_IsClosed THEN
        iBrakeOpenLatch := BRAKE_NONE;
    END_IF

    IF rtrModeOn.Q AND xEn_Overall AND xEn_Standstill AND xSB_IsClosed AND xBB_IsClosed THEN
        xBrakeModeActive := TRUE;
        iStep := STEP_READY;
    END_IF

(* ---------------------------------------------------------------- *)
STEP_READY:
    xOutSB_Open  := FALSE;
    xOutBB_Open  := FALSE;
    xBypassSB    := FALSE;
    xBypassBB    := FALSE;
    xTestRunning := FALSE;
    rTorqueSet   := 0.0;
    rRpmSet      := 0.0;

    IF xSB_IsClosed AND xBB_IsClosed THEN
        iBrakeOpenLatch := BRAKE_NONE;
    END_IF

    (* Apertura: si apre il freno che NON viene provato.
       Nel controllo del traferro si apre invece il freno selezionato stesso. *)
    IF rtrOpen.Q AND xEn_Open THEN
        iFaultCode           := ERR_NONE;
        xAckHazard           := FALSE;          (* la conferma e' consumata *)
        rSlipRev             := 0.0;
        rMaxRpmInTest        := 0.0;
        rTorqueReachedInTest := 0.0;
        xTestPassed          := FALSE;
        xTestFailed          := FALSE;

        IF iMode = MODE_AIRGAP THEN
            (* si apre il freno da controllare, l'altro tiene *)
            IF iBrakeSelected = BRAKE_SB THEN
                iBrakeOpenLatch := BRAKE_SB;
            ELSE
                iBrakeOpenLatch := BRAKE_BB;
            END_IF
        ELSE
            (* prova freni: si apre l'ALTRO freno, quello selezionato tiene la coppia *)
            IF iBrakeSelected = BRAKE_SB THEN
                iBrakeOpenLatch := BRAKE_BB;
            ELSE
                iBrakeOpenLatch := BRAKE_SB;
            END_IF
        END_IF
        iStep := STEP_OPENING;
    END_IF

    IF rtrModeOff.Q AND (iBrakeOpenLatch = BRAKE_NONE) AND xSB_IsClosed AND xBB_IsClosed THEN
        iStep := STEP_LOCKED;
    END_IF

(* ---------------------------------------------------------------- *)
STEP_OPENING:
    (* Il comando e' attivo e il feedback viene sorvegliato.
       L'interblocco iBrakeOpenLatch e' gia' impostato e resta tale finche'
       il freno non viene chiuso manualmente con feedback "chiuso" presente. *)
    xOutSB_Open := (iBrakeOpenLatch = BRAKE_SB);
    xOutBB_Open := (iBrakeOpenLatch = BRAKE_BB);
    rTorqueSet  := 0.0;
    rRpmSet     := 0.0;

    IF ((iBrakeOpenLatch = BRAKE_SB) AND xSB_IsOpen AND xBB_IsClosed)
    OR ((iBrakeOpenLatch = BRAKE_BB) AND xBB_IsOpen AND xSB_IsClosed) THEN
        iStep := STEP_OPEN;
    ELSIF tonOpen.Q THEN
        iFaultCode := ERR_FB_OPEN;
        iStep      := STEP_FAULT;
    END_IF

    (* Interruzione da parte dell'operatore, sempre possibile *)
    IF rtrClose.Q OR rtrTestStop.Q THEN
        iStep := STEP_CLOSING;
    END_IF

(* ---------------------------------------------------------------- *)
STEP_OPEN:
    (* Un freno e' aperto: si misura/regola il traferro oppure si avvia la prova.
       Senza prova in corso l'azionamento resta scarico.                       *)
    xOutSB_Open  := (iBrakeOpenLatch = BRAKE_SB);
    xOutBB_Open  := (iBrakeOpenLatch = BRAKE_BB);
    xTestRunning := FALSE;
    xBypassSB    := FALSE;
    xBypassBB    := FALSE;
    rTorqueSet   := 0.0;
    rRpmSet      := 0.0;

    IF rtrTestStart.Q AND xEn_TestStart THEN
        rSlipRev      := 0.0;
        rMaxRpmInTest := 0.0;
        xTestPassed   := FALSE;
        xTestFailed   := FALSE;
        iStep         := STEP_TEST_RAMP;
    END_IF

    IF rtrClose.Q THEN
        iStep := STEP_CLOSING;
    END_IF

(* ---------------------------------------------------------------- *)
STEP_TEST_RAMP:
    (* Salita a rampa della coppia contro il freno chiuso.
       Il setpoint giri resta nella finestra stretta di prova: se il freno
       tiene, l'azionamento resta fermo in limitazione di coppia.            *)
    xTestRunning := TRUE;
    xOutSB_Open  := (iBrakeOpenLatch = BRAKE_SB);
    xOutBB_Open  := (iBrakeOpenLatch = BRAKE_BB);
    xBypassSB    := (iBrakeSelected = BRAKE_SB);   (* SB chiusa: l'azionamento deve poter dare coppia *)
    xBypassBB    := (iBrakeSelected = BRAKE_BB);

    rTorqueSet := rTorqueSet + rTorqueRampPerSec * (CYCLE_MS / 1000.0);
    IF rTorqueSet > rTorqueTarget THEN
        rTorqueSet := rTorqueTarget;
    END_IF
    rRpmSet := rRpmTestSetpoint * rDirection;

    (* Sorveglianza dello slittamento *)
    rSlipRev := rSlipRev + ABS(rActRpm) / 60.0 * (CYCLE_MS / 1000.0);
    IF ABS(rActRpm) > rMaxRpmInTest THEN
        rMaxRpmInTest := ABS(rActRpm);
    END_IF
    rTorqueReachedInTest := ABS(rActTorque);

    IF (ABS(rActRpm) > rRpmSlipLimit) OR (rSlipRev > rSlipLimitRev) THEN
        xTestFailed     := TRUE;
        iLastTestResult := 2;
        iFaultCode      := ERR_TEST_FAILED;
        iStep           := STEP_TEST_RAMPDOWN;
    ELSIF rTorqueSet >= rTorqueTarget THEN
        iStep := STEP_TEST_HOLD;
    END_IF

    IF rtrTestStop.Q OR rtrClose.Q THEN
        iStep := STEP_TEST_RAMPDOWN;
    END_IF

(* ---------------------------------------------------------------- *)
STEP_TEST_HOLD:
    (* Mantenimento della coppia di prova per il tempo impostato *)
    xTestRunning := TRUE;
    xOutSB_Open  := (iBrakeOpenLatch = BRAKE_SB);
    xOutBB_Open  := (iBrakeOpenLatch = BRAKE_BB);
    xBypassSB    := (iBrakeSelected = BRAKE_SB);
    xBypassBB    := (iBrakeSelected = BRAKE_BB);
    rTorqueSet   := rTorqueTarget;
    rRpmSet      := rRpmTestSetpoint * rDirection;

    rSlipRev := rSlipRev + ABS(rActRpm) / 60.0 * (CYCLE_MS / 1000.0);
    IF ABS(rActRpm) > rMaxRpmInTest THEN
        rMaxRpmInTest := ABS(rActRpm);
    END_IF
    rTorqueReachedInTest := ABS(rActTorque);

    IF (ABS(rActRpm) > rRpmSlipLimit) OR (rSlipRev > rSlipLimitRev) THEN
        xTestFailed     := TRUE;
        iLastTestResult := 2;
        iFaultCode      := ERR_TEST_FAILED;
        iStep           := STEP_TEST_RAMPDOWN;
    ELSIF tonHold.Q THEN
        xTestPassed     := TRUE;
        iLastTestResult := 1;
        iStep           := STEP_TEST_RAMPDOWN;
    END_IF

    IF rtrTestStop.Q OR rtrClose.Q THEN
        iStep := STEP_TEST_RAMPDOWN;
    END_IF

(* ---------------------------------------------------------------- *)
STEP_TEST_RAMPDOWN:
    (* Discesa controllata della coppia. Il freno resta aperto: la chiusura
       manuale resta comunque obbligatoria.                                 *)
    xTestRunning := TRUE;
    xOutSB_Open  := (iBrakeOpenLatch = BRAKE_SB);
    xOutBB_Open  := (iBrakeOpenLatch = BRAKE_BB);
    xBypassSB    := (iBrakeSelected = BRAKE_SB);
    xBypassBB    := (iBrakeSelected = BRAKE_BB);
    rRpmSet      := 0.0;

    rTorqueSet := rTorqueSet - rTorqueRampPerSec * (CYCLE_MS / 1000.0);
    IF rTorqueSet <= 0.0 THEN
        rTorqueSet   := 0.0;
        xTestRunning := FALSE;
        xBypassSB    := FALSE;
        xBypassBB    := FALSE;
        IF xTestFailed THEN
            iStep := STEP_FAULT;      (* esito n.i.O.: va confermato con il reset *)
        ELSE
            iStep := STEP_OPEN;       (* freno ancora aperto, chiude l'operatore  *)
        END_IF
    END_IF

(* ---------------------------------------------------------------- *)
STEP_CLOSING:
    (* Chiusura manuale: tolto il comando, il freno si chiude a molla.
       Solo con il feedback "chiuso" l'interblocco cade e l'altro freno
       torna ad essere apribile.                                          *)
    xOutSB_Open  := FALSE;
    xOutBB_Open  := FALSE;
    xBypassSB    := FALSE;
    xBypassBB    := FALSE;
    xTestRunning := FALSE;
    rTorqueSet   := 0.0;
    rRpmSet      := 0.0;

    IF xSB_IsClosed AND xBB_IsClosed THEN
        iBrakeOpenLatch := BRAKE_NONE;         (* interblocco sbloccato *)
        IF iFaultCode <> ERR_NONE THEN
            iStep := STEP_FAULT;
        ELSE
            iStep := STEP_READY;
        END_IF
    ELSIF tonClose.Q THEN
        iFaultCode := ERR_FB_CLOSED;
        iStep      := STEP_FAULT;
    END_IF

(* ---------------------------------------------------------------- *)
STEP_FAULT:
    (* Stato sicuro: nessun comando di apertura, nessuna coppia.
       L'interblocco resta finche' il freno non e' chiuso e confermato. *)
    xOutSB_Open  := FALSE;
    xOutBB_Open  := FALSE;
    xBypassSB    := FALSE;
    xBypassBB    := FALSE;
    xTestRunning := FALSE;
    rTorqueSet   := 0.0;
    rRpmSet      := 0.0;

    IF rtrReset.Q THEN
        IF NOT (xSB_IsClosed AND xBB_IsClosed) THEN
            iStep := STEP_CLOSING;                  (* prima si chiude in modo pulito *)
        ELSIF xEn_Overall THEN
            iBrakeOpenLatch := BRAKE_NONE;
            iFaultCode      := ERR_NONE;
            xTestFailed     := FALSE;
            iStep           := STEP_READY;
        ELSE
            iFaultCode       := ERR_NONE;
            xBrakeModeActive := FALSE;
            iStep            := STEP_LOCKED;
        END_IF
    END_IF

ELSE
    iStep := STEP_LOCKED;
END_CASE

(* ================================================================================
   F) FORMAZIONE DELLO STATO E LIMITAZIONE DEI SETPOINT
   ================================================================================ *)
xBrakeIsOpen         := xBrakeModeActive
                    AND (xOutSB_Open OR xOutBB_Open OR xSB_IsOpen OR xBB_IsOpen);
xManualCloseRequired := (iBrakeOpenLatch <> BRAKE_NONE);
xDriveEnableTest     := xTestRunning AND xEn_Overall;

(* Doppia limitazione dei setpoint, indipendente dalla sequenza a passi *)
rTorqueSet := LIMIT(0.0, rTorqueSet, rTorqueMax);
rRpmLimit  := ABS(rRpmTestSetpoint);
rRpmSet    := LIMIT(-rRpmLimit, rRpmSet, rRpmLimit);
IF NOT xTestRunning THEN
    rTorqueSet := 0.0;
    rRpmSet    := 0.0;
END_IF

(* ================================================================================
   G) USCITE VERSO L'IMPIANTO
   ================================================================================ *)

(* --- G1: bit di bypass per la catena di consenso dei freni --- *)
g_IO.Standbremsentest := xBypassSB;
(* g_IO.Betriebsbremsentest := xBypassBB; *)   (*TODO*) (* creare la variabile in GVL e abilitare questa riga *)

(* Regola di base gia' presente: senza Service Mode nessun modo freni *)
IF NOT g_IO.ServiceMode THEN
    g_IO.Standbremsentest := FALSE;
    (* g_IO.Betriebsbremsentest := FALSE; *)   (*TODO*)
END_IF

(* --- G2: comando dei freni ---
   Solo nel modo freni questo PRG interviene sui freni; nel normale
   funzionamento la gestione esistente resta invariata.
   TODO: mappare sulle uscite reali di apertura dei freni: *)
IF xBrakeModeActive THEN
    (* g_IO.SB_Lueften := xOutSB_Open; *)   (*TODO*)
    (* g_IO.BB_Lueften := xOutBB_Open; *)   (*TODO*)
    ;
END_IF

(* --- G3: setpoint dell'azionamento ---
   Nel modo freni coppia e giri sono imposti esclusivamente qui.
   Richiamare il PRG nel task DOPO la gestione winda, cosi' questi valori valgono. *)
IF xBrakeModeActive THEN
    (*TODO*) (* verificare il tipo: se Solldrehmoment e' INT -> REAL_TO_INT(rTorqueSet) *)
    IO_Hauptinverter.Solldrehmoment  := rTorqueSet;
    IO_Hauptinverter.SollRpmInverter := REAL_TO_INT(LIMIT(-rRpmLimit, rRpmSet, rRpmLimit));
END_IF

(* ================================================================================
   H) TESTI DI DIAGNOSTICA PER LA VISU
      I testi restano in tedesco perche' sono destinati all'operatore in impianto;
      fra parentesi la traduzione italiana.
   ================================================================================ *)
CASE iStep OF
    STEP_LOCKED:         sStepText := 'Bremsmodus gesperrt';                    (* modo freni bloccato              *)
    STEP_READY:          sStepText := 'Bereit - Bremse und Funktion waehlen';   (* pronto: scegli freno e funzione  *)
    STEP_OPENING:        sStepText := 'Bremse wird geoeffnet';                  (* apertura del freno in corso      *)
    STEP_OPEN:           sStepText := 'Bremse OFFEN - Klemmgefahr!';            (* freno APERTO - schiacciamento!   *)
    STEP_TEST_RAMP:      sStepText := 'Bremstest - Moment wird aufgebaut';      (* prova: salita della coppia       *)
    STEP_TEST_HOLD:      sStepText := 'Bremstest - Pruefmoment wird gehalten';  (* prova: coppia mantenuta          *)
    STEP_TEST_RAMPDOWN:  sStepText := 'Bremstest - Moment wird abgebaut';       (* prova: discesa della coppia      *)
    STEP_CLOSING:        sStepText := 'Bremse manuell schliessen';              (* chiudere il freno manualmente    *)
    STEP_FAULT:          sStepText := 'Stoerung - quittieren';                  (* anomalia: eseguire il reset      *)
ELSE
    sStepText := '';
END_CASE

CASE iFaultCode OF
    ERR_NONE:            sFaultText := '';
    ERR_SERVICEMODE:     sFaultText := 'Service-Mode abgefallen';               (* Service Mode caduto              *)
    ERR_USERLEVEL:       sFaultText := 'Userlevel zu niedrig';                  (* livello utente insufficiente     *)
    ERR_ESTOP:           sFaultText := 'Not-Aus / Pilz nicht ok';               (* Notaus / Pilz non ok             *)
    ERR_BOTH_OPEN:       sFaultText := 'Beide Bremsen offen - unzulaessig!';    (* entrambi i freni aperti!         *)
    ERR_MOVEMENT:        sFaultText := 'Bewegung bei offener Bremse';           (* movimento a freno aperto         *)
    ERR_TORQUE:          sFaultText := 'Unzulaessiges Moment';                  (* coppia non ammessa               *)
    ERR_FB_OPEN:         sFaultText := 'Rueckmeldung OFFEN fehlt';              (* manca il feedback APERTO         *)
    ERR_FB_CLOSED:       sFaultText := 'Rueckmeldung ZU fehlt';                 (* manca il feedback CHIUSO         *)
    ERR_TEST_FAILED:     sFaultText := 'Bremstest n.i.O. - Bremse haelt nicht'; (* prova fallita: il freno non tiene*)
    ERR_OPEN_TIMEOUT:    sFaultText := 'Max. Offenzeit ueberschritten';         (* tempo massimo di apertura         *)
    ERR_OPMODE:          sFaultText := 'Betriebsart sperrt den Bremsmodus';     (* modo operativo incompatibile     *)
    ERR_DRIVE:           sFaultText := 'Umrichter nicht bereit';                (* inverter non pronto              *)
ELSE
    sFaultText := 'Unbekannte Stoerung';                                        (* anomalia sconosciuta             *)
END_CASE
