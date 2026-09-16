(* ================================================================================
   TestBremse_Controls   (PROGRAM / PRG)
   CODESYS 3.5.18.4 - Structured Text

   SCOPO
   -----
   Apertura FORZATA di UN SOLO freno della winda, in Service Mode.
   Niente prova freni, niente coppia imposta: qui si apre e si chiude, basta.

   REGOLE (da Hannes)
   ------------------
   * solo in Service Mode (chiave) e da livello utente 2
   * Notaus (Pilz) sempre attivo: se cade, il comando di apertura va via
   * winda ferma e azionamento scarico (giri e coppia reale sorvegliati)
   * prima si attiva il modo ManualTestBremse (status verso il PILZ), poi si apre
   * un solo freno aperto per volta
   * il freno aperto va richiuso MANUALMENTE (pulsante) e i due feedback "aperto"
     devono essere caduti da tSettle (5 s) prima che l'altro freno sia apribile

   DUE COSE DIVERSE, DA NON CONFONDERE
   -----------------------------------
   brakeCmd     = cosa sto COMANDANDO io da questa pagina (0 / 1 SB / 2 BB).
                  Solo questo diventa OutSB_Open / OutBB_Open.
   brakeOpenFb  = cosa SI VEDE in impianto dai feedback (0 / 1 SB / 2 BB / 3 entrambi).
                  E' solo uno stato: questo PRG non puo' chiudere un freno che non
                  ha aperto lui. Se brakeOpenFb <> 0 con brakeCmd = 0 si accende
                  WarnOpenExtern: o lo tiene aperto la gestione winda, o il
                  feedback non e' coerente (cablaggio / polarita' da verificare).

   INTERBLOCCO
   -----------
   E' BothClosedOk: comando tolto E nessun feedback "aperto", stabile per tSettle.
   Finche' e' FALSE non si apre niente. E' questa la chiusura manuale obbligatoria.

   TEMPI  (tSettle = 5 s, uno solo per apertura e chiusura)
   -------------------------------------------------------
   entrambi chiusi -> apro BB -> 5 s -> BrakeOpenOk
                   -> chiudo  -> 5 s -> BothClosedOk -> entrambi chiusi, si riparte

   SICUREZZA
   ---------
   Questo e' il livello FUNZIONALE nel PLC standard. L'interblocco vero
   (un solo freno aperto, Notaus, fermo macchina) sta nel PILZ, che riceve
   ManualTestBremse. Questo PRG non bypassa nessuna sicurezza.

   STRUTTURA
   ---------
   1) IN impianto   2) consenso   3) stato freni + tempi   4) modo
   5) consensi pulsanti   6) comandi   7) sorveglianza   8) OUT
   ================================================================================ *)

PROGRAM TestBremse_Controls
VAR
    (* --- 1) INGRESSI dall'impianto: immagine locale, il PRG li LEGGE soltanto --- *)
    in_ServiceMode      : BOOL;         (* g_IO.ServiceMode             - chiave service  *)
    in_UserLevel        : DINT;         (* CurrentUserLevel             - livello utente  *)
    in_NAok             : BOOL;         (* IOPilzWinde.K_NAok_VZ        - Notaus ok       *)
    in_Rpm              : REAL;         (* IO_Hauptinverter.ActualSpeed - giri/min        *)
    in_Torque           : REAL;         (* IO_Hauptinverter.ActualDM    - coppia reale    *)
    in_SBoffen          : BOOL;         (* g_IO.SBoffen - feedback: SB aperta             *)
    in_BBoffen          : BOOL;         (* g_IO.BBoffen - feedback: BB aperta             *)

    (* --- 2) INGRESSI dalla visu: pulsanti "a impulso", letti sul fronte --- *)
    CmdTestOn           : BOOL;         (* attiva il modo Manual Test Bremse          *)
    CmdTestOff          : BOOL;         (* esci dal modo                              *)
    CmdOpenSB           : BOOL;         (* apri freno di stazionamento (SB)           *)
    CmdOpenBB           : BOOL;         (* apri freno di servizio (BB)                *)
    CmdClose            : BOOL;         (* chiudi il freno aperto (obbligatorio)      *)

    (* --- 3) USCITE verso l'impianto e verso il PILZ --- *)
    ManualTestBremse    : BOOL;         (* status del modo -> PILZ                    *)
    OutSB_Open          : BOOL;         (* comando: apri SB                           *)
    OutBB_Open          : BOOL;         (* comando: apri BB                           *)

    (* --- 4) USCITE verso la visu --- *)
    EnableOk            : BOOL;         (* consenso generale (permanente)             *)
    enTestOn            : BOOL;         (* TRUE = pulsante "attiva modo" ammesso      *)
    enTestOff           : BOOL;         (* TRUE = pulsante "esci dal modo" ammesso    *)
    enOpenSB            : BOOL;         (* TRUE = pulsante "apri SB" ammesso          *)
    enOpenBB            : BOOL;         (* TRUE = pulsante "apri BB" ammesso          *)
    enClose             : BOOL;         (* TRUE = pulsante "chiudi" ammesso           *)
    brakeOpenFb         : INT := 0;     (* STATO dai feedback: 0 / 1 SB / 2 BB / 3 entrambi *)
    BrakeOpenOk         : BOOL;         (* freno aperto da me e feedback presente dopo 5 s  *)
    BothClosedOk        : BOOL;         (* INTERBLOCCO LIBERO: tutti chiusi da 5 s    *)
    ManualCloseRequired : BOOL;         (* un freno risulta aperto: va richiuso       *)
    FaultBothOpen       : BOOL;         (* ANOMALIA: risultano aperti tutti e due     *)
    WarnNoFeedback      : BOOL;         (* dopo 5 s manca il feedback "aperto"        *)
    WarnOpenExtern      : BOOL;         (* freno aperto SENZA comando da questa pagina*)

    (* --- 5) PARAMETRI --- *)
    RpmStandstill       : REAL := 2.0;    (* giri/min ammessi: winda ferma            *)
    TorqueFreeLimit     : REAL := 50.0;   (* coppia reale ammessa: azionamento scarico*)
    MinUserLevel        : DINT := 2;      (* livello utente minimo                    *)
    tSettle             : TIME := T#5S;   (* tempo di assestamento apertura/chiusura  *)

    (* --- 6) INTERNE --- *)
    brakeCmd            : INT := 0;     (* freno comandato aperto: 0 / 1 SB / 2 BB    *)
    tonOpen             : TON;          (* 5 s dal comando di apertura                *)
    tonClosed           : TON;          (* 5 s con tutti e due i freni chiusi         *)
    rtrTestOn           : R_TRIG;
    rtrTestOff          : R_TRIG;
    rtrOpenSB           : R_TRIG;
    rtrOpenBB           : R_TRIG;
    rtrClose            : R_TRIG;
END_VAR

(* ---- 1) INGRESSI -------------------------------------------------------------- *)
in_ServiceMode := g_IO.ServiceMode;
in_UserLevel   := CurrentUserLevel;
in_NAok        := IOPilzWinde.K_NAok_VZ;
in_Rpm         := IO_Hauptinverter.ActualSpeed;
in_Torque      := IO_Hauptinverter.ActualDM;
in_SBoffen     := g_IO.SBoffen;
in_BBoffen     := g_IO.BBoffen;

(* ---- 2) CONSENSO GENERALE ----------------------------------------------------- *)
(* Condizione PERMANENTE: se cade, il comando di apertura va via subito e il
   freno si chiude a molla (sezione 7). *)
EnableOk := in_ServiceMode
        AND (in_UserLevel >= MinUserLevel)
        AND in_NAok
        AND (ABS(in_Rpm) <= RpmStandstill)
        AND (ABS(in_Torque) <= TorqueFreeLimit);

(* ---- 3) STATO DEI FRENI DAL FEEDBACK E TEMPI ---------------------------------- *)
(* Solo fotografia dell'impianto, nessun comando e nessuna memoria *)
IF in_SBoffen AND in_BBoffen THEN
    brakeOpenFb := 3;                               (* 3 = tutti e due, non ammesso *)
ELSIF in_SBoffen THEN
    brakeOpenFb := 1;                               (* 1 = SB *)
ELSIF in_BBoffen THEN
    brakeOpenFb := 2;                               (* 2 = BB *)
ELSE
    brakeOpenFb := 0;                               (* 0 = tutti e due chiusi *)
END_IF
FaultBothOpen := (brakeOpenFb = 3);

(* 5 s dal comando di apertura: dopo questo tempo il feedback deve esserci *)
tonOpen(IN := (brakeCmd <> 0), PT := tSettle);
BrakeOpenOk    := tonOpen.Q AND (((brakeCmd = 1) AND in_SBoffen)
                              OR ((brakeCmd = 2) AND in_BBoffen));
WarnNoFeedback := tonOpen.Q AND NOT BrakeOpenOk;

(* INTERBLOCCO: comando tolto e nessun feedback "aperto", stabile per 5 s.
   Finche' e' FALSE non si apre niente: e' la chiusura manuale obbligatoria. *)
tonClosed(IN := (brakeCmd = 0) AND (brakeOpenFb = 0), PT := tSettle);
BothClosedOk := tonClosed.Q;

(* Freno aperto che NON ho aperto io: da questa pagina non si chiude.
   Verificare la gestione winda e la coerenza del feedback "offen". *)
WarnOpenExtern      := (brakeOpenFb <> 0) AND (brakeCmd = 0);
ManualCloseRequired := (brakeOpenFb <> 0);

(* ---- 4) MODO MANUAL TEST BREMSE ----------------------------------------------- *)
rtrTestOn(CLK := CmdTestOn);
rtrTestOff(CLK := CmdTestOff);

(* Nel modo si entra anche con un freno gia' aperto: l'interblocco BothClosedOk
   non lascia comunque aprire niente finche' quel freno non e' chiuso. *)
IF rtrTestOn.Q AND EnableOk THEN
    ManualTestBremse := TRUE;
END_IF

(* Si esce dal modo quando questa pagina non comanda piu' nessuna apertura.
   Un freno tenuto aperto da altri non deve incastrare l'operatore qui dentro. *)
IF (rtrTestOff.Q OR NOT EnableOk) AND (brakeCmd = 0) THEN
    ManualTestBremse := FALSE;
END_IF

(* ---- 5) CONSENSI DEI PULSANTI (li legge la visu) ------------------------------ *)
enTestOn  := EnableOk AND NOT ManualTestBremse;
enTestOff := ManualTestBremse AND (brakeCmd = 0);

(* Si apre solo con: modo attivo, consenso ok, niente comandato,
   e interblocco libero (tutti e due i freni chiusi da 5 s) *)
enOpenSB := ManualTestBremse AND EnableOk AND (brakeCmd = 0) AND BothClosedOk;
enOpenBB := ManualTestBremse AND EnableOk AND (brakeCmd = 0) AND BothClosedOk;

(* Il pulsante "chiudi" ha senso solo su un freno aperto da questa pagina *)
enClose := ManualTestBremse AND (brakeCmd <> 0);

(* ---- 6) COMANDI SUL FRONTE DI SALITA ------------------------------------------ *)
rtrOpenSB(CLK := CmdOpenSB);
rtrOpenBB(CLK := CmdOpenBB);
rtrClose(CLK := CmdClose);

IF rtrOpenSB.Q AND enOpenSB THEN
    brakeCmd := 1;                                  (* 1 = SB *)
END_IF

IF rtrOpenBB.Q AND enOpenBB THEN
    brakeCmd := 2;                                  (* 2 = BB *)
END_IF

IF rtrClose.Q THEN
    brakeCmd := 0;                                  (* comando tolto -> il freno chiude a molla *)
END_IF

(* ---- 7) SORVEGLIANZA PERMANENTE ----------------------------------------------- *)
(* Consenso caduto, modo non attivo, o tutti e due i freni aperti:
   il comando di apertura va via subito. L'interblocco resta. *)
IF NOT EnableOk OR NOT ManualTestBremse OR FaultBothOpen THEN
    brakeCmd := 0;
END_IF

(* ---- 8) USCITE ---------------------------------------------------------------- *)
OutSB_Open := (brakeCmd = 1);
OutBB_Open := (brakeCmd = 2);

(* g_IO.SB_Lueften        := OutSB_Open;       *)   (*TODO*) (* uscita reale SB      *)
(* g_IO.BB_Lueften        := OutBB_Open;       *)   (*TODO*) (* uscita reale BB      *)
(* g_IO.ManualTestBremse  := ManualTestBremse; *)   (*TODO*) (* variabile verso PILZ *)
