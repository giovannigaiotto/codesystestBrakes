(* ================================================================================
   TestBremse_Controls   (PROGRAM / PRG)
   CODESYS 3.5.18.4 - Structured Text

   SCOPO
   -----
   Comando MANUALE dei due freni della winda in Service Mode: apertura e chiusura,
   un freno per volta. Niente prova freni, niente coppia imposta.

   PUNTO CHIAVE: NEL MODO I FRENI LI COMANDO IO
   --------------------------------------------
   Finche' ManualTestBremse e' TRUE, le uscite dei freni le scrive QUESTO PRG,
   tutti i cicli, anche a FALSE. E' l'unico modo per poter CHIUDERE un freno che
   trovo gia' aperto. Fuori dal modo le uscite restano alla gestione winda.
   -> il PRG va richiamato nel task DOPO la gestione winda
   -> vanno collegate le uscite reali in fondo (sezione 8, righe TODO):
      senza quelle nessun pulsante muove niente in impianto.

   STATO DI PARTENZA TIPICO: SB aperta, BB chiusa
   ----------------------------------------------
   Attivo il modo -> i comandi partono da zero -> la SB viene comandata chiusa.
   Quando i due feedback "aperto" sono caduti da tSettle, si puo' aprire il freno
   che si vuole. Il pulsante CHIUDI di ogni freno e' comunque sempre disponibile.

   REGOLE (da Hannes)
   ------------------
   * solo in Service Mode (chiave) e da livello utente 2
   * Notaus (Pilz) sempre attivo: se cade, i comandi di apertura vanno via
   * winda ferma e azionamento scarico (giri e coppia reale sorvegliati)
   * un solo freno aperto per volta
   * il freno aperto va richiuso a mano e i feedback "aperto" devono essere caduti
     da tSettle (5 s) prima che l'altro freno sia apribile
   * il pulsante OFF esce SEMPRE dal modo e riporta tutti i comandi a zero:
     e' la via d'uscita sicura, non va mai bloccata

   DUE COSE DIVERSE, DA NON CONFONDERE
   -----------------------------------
   cmdSB_Open / cmdBB_Open = cosa COMANDO io -> OutSB_Open / OutBB_Open
   brakeOpenFb             = cosa VEDO dai feedback (0 / 1 SB / 2 BB / 3 entrambi)
   Se i feedback dicono "aperto" mentre non comando niente si accende
   WarnOpenExtern: o le uscite non sono ancora collegate (righe TODO), o il freno
   lo tiene aperto qualcun altro, o il feedback non e' coerente.

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
    CmdTestOff          : BOOL;         (* esci dal modo (sempre ammesso)             *)
    CmdOpenSB           : BOOL;         (* apri SB   - freno di stazionamento         *)
    CmdCloseSB          : BOOL;         (* chiudi SB                                  *)
    CmdOpenBB           : BOOL;         (* apri BB   - freno di servizio              *)
    CmdCloseBB          : BOOL;         (* chiudi BB                                  *)

    (* --- 3) USCITE verso l'impianto e verso il PILZ --- *)
    ManualTestBremse    : BOOL;         (* status del modo -> PILZ                    *)
    OutSB_Open          : BOOL;         (* comando: apri SB                           *)
    OutBB_Open          : BOOL;         (* comando: apri BB                           *)

    (* --- 4) USCITE verso la visu --- *)
    EnableOk            : BOOL;         (* consenso generale (permanente)             *)
    enTestOn            : BOOL;         (* TRUE = pulsante "attiva modo" ammesso      *)
    enTestOff           : BOOL;         (* TRUE = pulsante "esci dal modo" ammesso    *)
    enOpenSB            : BOOL;         (* TRUE = pulsante "apri SB" ammesso          *)
    enCloseSB           : BOOL;         (* TRUE = pulsante "chiudi SB" ammesso        *)
    enOpenBB            : BOOL;         (* TRUE = pulsante "apri BB" ammesso          *)
    enCloseBB           : BOOL;         (* TRUE = pulsante "chiudi BB" ammesso        *)
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
    cmdSB_Open          : BOOL;         (* comando interno: SB aperta                 *)
    cmdBB_Open          : BOOL;         (* comando interno: BB aperta                 *)
    tonOpen             : TON;          (* 5 s dal comando di apertura                *)
    tonClosed           : TON;          (* 5 s con tutti e due i freni chiusi         *)
    rtrTestOn           : R_TRIG;
    rtrTestOff          : R_TRIG;
    rtrOpenSB           : R_TRIG;
    rtrCloseSB          : R_TRIG;
    rtrOpenBB           : R_TRIG;
    rtrCloseBB          : R_TRIG;
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
(* Condizione PERMANENTE: se cade, i comandi di apertura vanno via subito e i
   freni si chiudono a molla (sezione 7). Non blocca mai la CHIUSURA. *)
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
tonOpen(IN := cmdSB_Open OR cmdBB_Open, PT := tSettle);
BrakeOpenOk    := tonOpen.Q AND ((cmdSB_Open AND in_SBoffen)
                              OR (cmdBB_Open AND in_BBoffen));
WarnNoFeedback := tonOpen.Q AND NOT BrakeOpenOk;

(* INTERBLOCCO: nessun comando di apertura e nessun feedback "aperto", da 5 s.
   Finche' e' FALSE non si apre niente: e' la chiusura manuale obbligatoria. *)
tonClosed(IN := NOT cmdSB_Open AND NOT cmdBB_Open AND (brakeOpenFb = 0), PT := tSettle);
BothClosedOk := tonClosed.Q;

(* Freno aperto mentre non comando niente: uscite non ancora collegate (TODO
   sezione 8), freno tenuto aperto da altri, oppure feedback non coerente. *)
WarnOpenExtern      := (brakeOpenFb <> 0) AND NOT cmdSB_Open AND NOT cmdBB_Open;
ManualCloseRequired := (brakeOpenFb <> 0);

(* ---- 4) MODO MANUAL TEST BREMSE ----------------------------------------------- *)
rtrTestOn(CLK := CmdTestOn);
rtrTestOff(CLK := CmdTestOff);

(* ON: si entra anche con un freno gia' aperto. I comandi partono da zero, quindi
   nel modo quel freno viene comandato CHIUSO. *)
IF rtrTestOn.Q AND EnableOk THEN
    ManualTestBremse := TRUE;
    cmdSB_Open       := FALSE;
    cmdBB_Open       := FALSE;
END_IF

(* OFF: sempre possibile, e' la via d'uscita sicura. Tutto a zero, i freni
   chiudono a molla e le uscite tornano alla gestione winda. *)
IF rtrTestOff.Q THEN
    ManualTestBremse := FALSE;
    cmdSB_Open       := FALSE;
    cmdBB_Open       := FALSE;
END_IF

(* La chiave di Service Mode e' la premessa del modo: se cade, il modo cade e le
   uscite dei freni tornano subito alla gestione winda. *)
IF NOT in_ServiceMode THEN
    ManualTestBremse := FALSE;
    cmdSB_Open       := FALSE;
    cmdBB_Open       := FALSE;
END_IF

(* ---- 5) CONSENSI DEI PULSANTI (li legge la visu) ------------------------------ *)
enTestOn  := EnableOk AND NOT ManualTestBremse;
enTestOff := ManualTestBremse;

(* Si apre solo con: modo attivo, consenso ok, interblocco libero
   (nessun comando e tutti e due i freni chiusi da 5 s) *)
enOpenSB := ManualTestBremse AND EnableOk AND BothClosedOk;
enOpenBB := ManualTestBremse AND EnableOk AND BothClosedOk;

(* Chiudere e' sempre ammesso nel modo, finche' il freno e' comandato o
   risulta aperto. Nessun consenso davanti alla chiusura. *)
enCloseSB := ManualTestBremse AND (cmdSB_Open OR in_SBoffen);
enCloseBB := ManualTestBremse AND (cmdBB_Open OR in_BBoffen);

(* ---- 6) COMANDI SUL FRONTE DI SALITA ------------------------------------------ *)
rtrOpenSB(CLK := CmdOpenSB);
rtrCloseSB(CLK := CmdCloseSB);
rtrOpenBB(CLK := CmdOpenBB);
rtrCloseBB(CLK := CmdCloseBB);

IF rtrOpenSB.Q AND enOpenSB THEN
    cmdSB_Open := TRUE;
    cmdBB_Open := FALSE;                            (* mai tutti e due *)
END_IF

IF rtrOpenBB.Q AND enOpenBB THEN
    cmdBB_Open := TRUE;
    cmdSB_Open := FALSE;                            (* mai tutti e due *)
END_IF

(* La chiusura non ha condizioni: toglie il comando e il freno chiude a molla *)
IF rtrCloseSB.Q THEN
    cmdSB_Open := FALSE;
END_IF

IF rtrCloseBB.Q THEN
    cmdBB_Open := FALSE;
END_IF

(* ---- 7) SORVEGLIANZA PERMANENTE ----------------------------------------------- *)
(* Consenso caduto, modo non attivo, o tutti e due i freni aperti:
   i comandi di apertura vanno via subito. *)
IF NOT EnableOk OR NOT ManualTestBremse OR FaultBothOpen THEN
    cmdSB_Open := FALSE;
    cmdBB_Open := FALSE;
END_IF

(* ---- 8) USCITE ---------------------------------------------------------------- *)
OutSB_Open := cmdSB_Open;
OutBB_Open := cmdBB_Open;

(* NEL MODO LE USCITE DEI FRENI LE SCRIVE QUESTO PRG, ANCHE A FALSE:
   e' quello che permette di CHIUDERE un freno trovato aperto.
   Fuori dal modo non si tocca niente, comanda la gestione winda. *)
IF ManualTestBremse THEN
    (* g_IO.SB_Lueften := OutSB_Open; *)            (*TODO*) (* uscita reale SB      *)
    (* g_IO.BB_Lueften := OutBB_Open; *)            (*TODO*) (* uscita reale BB      *)
    ;
END_IF

(* g_IO.ManualTestBremse := ManualTestBremse; *)    (*TODO*) (* variabile verso PILZ *)
