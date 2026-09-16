(* ================================================================================
   TestBremse_Controls   (PROGRAM / PRG)
   CODESYS 3.5.18.4 - Structured Text

   SCOPO
   -----
   Gestione guidata e interbloccata dei due freni della winda in Service Mode:
     1) Controllo Lueftspalt (traferro) -> si apre UN solo freno, l'altro tiene
     2) Bremstest (prova freni)         -> coppia rampata contro il freno chiuso
                                           con sorveglianza dello slittamento

   Sigle dei freni (come nell'impianto):
     SB = Standbremse    = freno di stazionamento
     BB = Betriebsbremse = freno di servizio

   REGOLE (da Hannes)
   ------------------
   * Utilizzabile solo in Service Mode (chiave fisica) e da livello utente 2
   * Il Notaus resta sempre attivo ed e' condizione di consenso
   * Puo' essere aperto un solo freno per volta
   * Il freno aperto va richiuso MANUALMENTE prima di poter aprire l'altro
     (interblocco bremseOpenLatch)
   * Giri e coppia sono sorvegliati in permanenza: in caso di movimento o di
     coppia non ammessa i setpoint vengono azzerati e i freni si chiudono

   ATTENZIONE SICUREZZA
   --------------------
   Questa sequenza e' il blocco FUNZIONALE nel PLC standard.
   L'interblocco di sicurezza vero (un solo freno aperto, Notaus, sorveglianza di
   fermo macchina e dei giri, limitazione sicura della coppia) va realizzato e
   valutato nella sicurezza PILZ. Questo PLC non deve bypassare nessuna sicurezza.

   CONVENZIONI DI NOME
   -------------------
   * nessun prefisso di tipo (niente x / i / s / r)
   * to... = istanza TON      (esempio toOpen)
   * tf... = istanza TOF
   * t...  = valore di tempo  (esempio tMonOpen := T#3S)
   * niente VAR CONSTANT: i numeri stanno nel codice, con il commento del
     significato a fianco

   LEGENDA DEI NUMERI USATI NEL CODICE
   -----------------------------------
   act_step (passo della sequenza):
        0 = modo freni bloccato          10 = pronto (entrambi chiusi)
       20 = apertura in corso            30 = un freno aperto
       40 = prova: salita coppia         50 = prova: mantenimento coppia
       60 = prova: discesa coppia        70 = chiusura manuale
       90 = anomalia (serve il reset)

   bremse_Selected / bremseOpenLatch (quale freno):
        0 = nessuno    1 = SB (Standbremse)    2 = BB (Betriebsbremse)

   mode_bremsetest (funzione scelta):
        0 = nessuna    1 = controllo traferro (nessuna coppia)
        2 = prova freni (coppia contro il freno chiuso)

   errorCodeBremse (anomalia):
        0 = nessuna              1 = Service Mode caduto
        2 = livello utente < 2   3 = Notaus / Pilz non ok
        4 = entrambi i freni aperti        5 = movimento a freno aperto
        6 = coppia reale non ammessa       7 = manca feedback "aperto"
        8 = manca feedback "chiuso"        9 = prova fallita, il freno non tiene
       10 = superato il tempo massimo di apertura
       11 = modo operativo che blocca (messa in servizio / simulazione)
       12 = inverter non pronto

   lastTestResult (esito ultima prova):
        0 = nessuna prova    1 = i.O. (superata)    2 = n.i.O. (fallita)

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
VAR
    (* visu var *)
    (* ============================================================================
       PULSANTI  -  la visu scrive, il PRG legge il FRONTE
       Configurare i pulsanti come "variabile a impulso" (FALSE->TRUE).
       Blocco gia' presente nella visu, da mantenere:
       ((IOPilzWinde.K_NAok_VZ) AND (g_IO.ServiceMode) AND (CurrentUserLevel>=2)) = FALSE
       ============================================================================ *)
    CmdModeOn              : BOOL;   (* pulsante: entra nel modo freni                  *)
    CmdModeOff             : BOOL;   (* pulsante: esci dal modo freni                   *)
    CmdSelectSB            : BOOL;   (* pulsante: seleziona freno di stazionamento (SB) *)
    CmdSelectBB            : BOOL;   (* pulsante: seleziona freno di servizio (BB)      *)
    CmdSelectAirgap        : BOOL;   (* pulsante: funzione controllo traferro           *)
    CmdSelectBrakeTest     : BOOL;   (* pulsante: funzione prova freni                  *)
    AckHazard              : BOOL;   (* pulsante: conferma pericolo schiacciamento      *)
    CmdOpen                : BOOL;   (* pulsante: apri il freno                         *)
    CmdClose               : BOOL;   (* pulsante: chiudi il freno (obbligatorio)        *)
    CmdTestStart           : BOOL;   (* pulsante: avvia la prova freni                  *)
    CmdTestStop            : BOOL;   (* pulsante: interrompi la prova freni             *)
    CmdReset               : BOOL;   (* pulsante: reset anomalia                        *)
    TestDirection          : INT := 1;  (* selettore visu: +1 senso di tiro, -1 opposto *)

    (* visu var *)
    (* ============================================================================
       ENABLE DEI PULSANTI  -  il PRG scrive, la visu legge
       Da usare come "invisibile/disabilitato" sui rispettivi pulsanti.
       ============================================================================ *)
    enOpen                 : BOOL;   (* TRUE = il pulsante "apri" e' ammesso            *)
    enTestStart            : BOOL;   (* TRUE = il pulsante "avvia prova" e' ammesso     *)
    enClose                : BOOL;   (* TRUE = il pulsante "chiudi" ha senso            *)
    enSelection            : BOOL;   (* TRUE = selezione freno/funzione ammessa         *)

    (* visu var *)
    (* ============================================================================
       CURSORI / CAMPI DI IMMISSIONE  -  parametri regolabili
       Tutti i valori vanno tarati sull'impianto (volendo da tenere PERSISTENT).
       ============================================================================ *)
    RpmTripOpen            : REAL := 5.0;    (* giri/min: movimento a freno aperto -> stop   *)
    RpmSlipLimit           : REAL := 3.0;    (* giri/min: slittamento ammesso nella prova    *)
    RpmTestSetpoint        : REAL := 5.0;    (* giri/min: setpoint giri durante la prova     *)
    SlipLimitRev           : REAL := 0.05;   (* giri albero: rotazione ammessa nella prova   *)
    TorqueTestSB           : REAL := 0.0;    (* coppia di prova SB  -> da parametrizzare     *)
    TorqueTestBB           : REAL := 0.0;    (* coppia di prova BB  -> da parametrizzare     *)
    TorqueMax              : REAL := 0.0;    (* limite superiore duro -> da parametrizzare   *)
    TorqueRampPerSec       : REAL := 10.0;   (* incremento di coppia al secondo              *)
    AutoCloseOnTimeout     : BOOL := FALSE;  (* TRUE: chiude d'ufficio dopo tMaxBremseOpen   *)

    (* visu var *)
    (* ---- tempi regolabili ---- *)
    tTestHoldDM            : TIME := T#5S;   (* mantenimento della coppia di prova           *)
    tMonOpen               : TIME := T#3S;   (* attesa massima del feedback "aperto"         *)
    tMonClose              : TIME := T#3S;   (* attesa massima del feedback "chiuso"         *)
    tMaxBremseOpen         : TIME := T#30M;  (* tempo massimo con un freno aperto            *)
    tAckValid              : TIME := T#60S;  (* validita' della conferma del pericolo        *)
    tMonTorqueFree         : TIME := T#1S;   (* ritardo sorveglianza "coppia libera"         *)
    tCycle                 : REAL := 10.0;   (* ms di ciclo del task: TODO allineare al task *)

    (* visu var *)
    (* ============================================================================
       LED / SPIE  -  il PRG scrive, la visu legge
       ============================================================================ *)
    ledBrakeModeActive     : BOOL;   (* verde: modo freni attivo                        *)
    ledBrakeIsOpen         : BOOL;   (* rosso lampeggiante: un freno e' APERTO          *)
    ledTestRunning         : BOOL;   (* giallo: prova freni in corso                    *)
    ledTestPassed          : BOOL;   (* verde: ultima prova i.O.                        *)
    ledTestFailed          : BOOL;   (* rosso: ultima prova n.i.O.                      *)
    ledManualCloseRequired : BOOL;   (* giallo: chiusura manuale ancora richiesta       *)
    ledWarnOpenTime        : BOOL;   (* giallo: freno aperto da troppo tempo            *)
    ledSB_Selected         : BOOL;   (* spia: SB selezionata                            *)
    ledBB_Selected         : BOOL;   (* spia: BB selezionata                            *)
    ledModeAirgap          : BOOL;   (* spia: funzione traferro selezionata             *)
    ledModeBrakeTest       : BOOL;   (* spia: funzione prova freni selezionata          *)
    ledFault               : BOOL;   (* rosso: anomalia presente, serve il reset        *)

    (* visu var *)
    (* ============================================================================
       VALORI DA VISUALIZZARE  -  il PRG scrive, la visu legge
       ============================================================================ *)
    act_step               : INT := 0;  (* passo attuale, vedi legenda in testa         *)
    errorCodeBremse        : INT := 0;  (* codice anomalia, vedi legenda in testa       *)
    lastTestResult         : INT := 0;  (* 0 nessuna prova / 1 i.O. / 2 n.i.O.          *)
    TorqueSet              : REAL;      (* coppia di riferimento rampata, verso inverter*)
    RpmSet                 : REAL;      (* setpoint giri, verso inverter                *)
    SlipRev                : REAL;      (* giri di slittamento integrati nella prova    *)
    MaxRpmInTest           : REAL;      (* picco giri/min durante la prova              *)
    TorqueReachedInTest    : REAL;      (* coppia reale raggiunta nella prova           *)

    (* visu var *)
    (* ---- testi per l'operatore (in tedesco) ---- *)
    StepText               : STRING(80);  (* riga di stato                              *)
    FaultText              : STRING(80);  (* riga di anomalia                           *)

    (* ============================================================================
       VARIABILI TEMPORANEE
       Immagine locale degli ingressi e dei consensi: per ora prese dalla GVL /
       simulate, in seguito vanno sostituite con i segnali veri scambiati con la
       sicurezza PILZ.
       ============================================================================ *)
    ServiceMode            : BOOL;   (* chiave di Service Mode          -> PILZ         *)
    NotausOK               : BOOL;   (* catena Notaus in ordine         -> PILZ         *)
    UserLevel              : INT;    (* livello utente attuale dal display              *)
    SB_offen               : BOOL;   (* feedback: SB aperta                             *)
    SB_zu                  : BOOL;   (* feedback: SB chiusa                             *)
    BB_offen               : BOOL;   (* feedback: BB aperta                             *)
    BB_zu                  : BOOL;   (* feedback: BB chiusa                             *)
    ActRpm                 : REAL;   (* giri reali dall'inverter                        *)
    ActTorque              : REAL;   (* coppia reale dall'inverter                      *)
    DriveReady             : BOOL;   (* inverter pronto, senza blocchi                  *)
    opModeBlock            : BOOL;   (* modo operativo che vieta il modo freni          *)
    forceBlockinTest       : BOOL := TRUE;  (* consenso provvisorio da banco: al posto
                                               del consenso che arrivera' dal PILZ      *)
    simBremsen             : BOOL;   (* TRUE = feedback freni simulati (solo banco)     *)
    simSB                  : BOOL;   (* simulazione: SB aperta                          *)
    simBB                  : BOOL;   (* simulazione: BB aperta                          *)
    BremsentestSB          : BOOL;   (* bit di bypass SB -> g_IO.Standbremsentest       *)
    BremsentestBB          : BOOL;   (* bit di bypass BB -> g_IO.Betriebsbremsentest    *)

    (* ============================================================================
       CONSENSI INTERNI
       ============================================================================ *)
    ok_UserLevel           : BOOL;   (* livello utente sufficiente                      *)
    enable_OpMode          : BOOL;   (* nessun modo operativo in conflitto              *)
    enable_Drive           : BOOL;   (* inverter pronto                                 *)
    enable_Standstill      : BOOL;   (* giri entro la finestra ammessa                  *)
    enable_TorqueFree      : BOOL;   (* coppia reale entro la finestra ammessa          *)
    enable_general_ok      : BOOL;   (* condizione PERMANENTE del modo freni            *)

    (* ============================================================================
       STATO INTERNO E USCITE VERSO L'IMPIANTO
       ============================================================================ *)
    BrakeModeActive        : BOOL;   (* modo freni attivo -> blocca il normale funzionamento *)
    BrakeIsOpen            : BOOL;   (* un freno risulta aperto                         *)
    TestRunning            : BOOL;   (* prova freni in corso                            *)
    TestPassed             : BOOL;   (* esito prova i.O.                                *)
    TestFailed             : BOOL;   (* esito prova n.i.O.                              *)
    ManualCloseRequired    : BOOL;   (* interblocco attivo fino alla chiusura manuale   *)
    OutSB_Open             : BOOL;   (* comando di apertura SB                          *)
    OutBB_Open             : BOOL;   (* comando di apertura BB                          *)
    DriveEnableTest        : BOOL;   (* consenso inverter solo durante la prova         *)
    WarnOpenTime           : BOOL;   (* avviso tempo massimo di apertura                *)

    bremse_Selected        : INT := 0;  (* freno scelto dall'operatore: 0/1/2           *)
    bremseOpenLatch        : INT := 0;  (* INTERBLOCCO: quale freno e'/era aperto 0/1/2 *)
    mode_bremsetest        : INT := 0;  (* funzione scelta: 0/1/2                       *)

    TorqueTarget           : REAL;   (* coppia di prova del freno selezionato           *)
    RpmLimit               : REAL;   (* limite giri applicato al setpoint               *)
    Direction              : REAL := 1.0;  (* +1.0 / -1.0 ricavato da TestDirection     *)

    (* ============================================================================
       RILEVAMENTO FRONTI
       ============================================================================ *)
    rtrModeOn              : R_TRIG;
    rtrModeOff             : R_TRIG;
    rtrSelSB               : R_TRIG;
    rtrSelBB               : R_TRIG;
    rtrSelAirgap           : R_TRIG;
    rtrSelBrakeTest        : R_TRIG;
    rtrOpen                : R_TRIG;
    rtrClose               : R_TRIG;
    rtrTestStart           : R_TRIG;
    rtrTestStop            : R_TRIG;
    rtrReset               : R_TRIG;

    (* ============================================================================
       TEMPORIZZATORI (to... = TON)
       ============================================================================ *)
    toOpen                 : TON;    (* sorveglianza feedback "aperto"                  *)
    toClose                : TON;    (* sorveglianza feedback "chiuso"                  *)
    toHold                 : TON;    (* tempo di mantenimento della prova               *)
    toMaxOpen              : TON;    (* tempo massimo con freno aperto                  *)
    toAck                  : TON;    (* scadenza della conferma del pericolo            *)
    toTorqueFree           : TON;    (* sorveglianza ritardata "coppia libera"          *)
END_VAR

(* ================================================================================
   A) INTERFACCIA VERSO L'IMPIANTO - lettura dei valori reali
      TODO: verificare una sola volta nomi e tipi rispetto al progetto
   ================================================================================ *)
ServiceMode := g_IO.ServiceMode;
NotausOK    := IOPilzWinde.K_NAok_VZ;                        (* catena Notaus ok, ritardata *)
UserLevel   := CurrentUserLevel;                             (*TODO*) (* sorgente del livello utente *)

SB_offen    := g_IO.SBoffen;
SB_zu       := NOT g_IO.SBoffen;                             (*TODO*) (* se esiste "SBzu" dedicato, usarlo *)
BB_offen    := g_IO.BBoffen;
BB_zu       := g_IO.BBzu;

ActRpm      := IO_Hauptinverter.ActualSpeed;                 (*TODO*) (* se ActualSpeed e' INT -> INT_TO_REAL(...) *)
ActTorque   := IO_Hauptinverter.ActualDM;                    (*TODO*) (* nome/tipo del valore reale coppia *)
DriveReady  := IO_Hauptinverter.Bereit;                      (*TODO*) (* segnale di pronto / blocco        *)

(* Modi di funzionamento che escludono il modo freni *)
opModeBlock := App_Winde.inbetriebnahme;                     (*TODO*) (* eventualmente OR comando di marcia *)
(* simBremsen NON blocca il modo freni: serve proprio per provare la sequenza
   al banco con i feedback simulati *)

(* Simulazione dei feedback: SOLO da banco, mai in impianto.
   Riprende il blocco gia' usato finora e sovrascrive l'immagine locale. *)
IF simBremsen AND ServiceMode THEN
    g_IO.SBoffen := simSB;
    g_IO.BBoffen := simBB;
    g_IO.BBzu    := NOT simBB;
    SB_offen     := simSB;
    SB_zu        := NOT simSB;
    BB_offen     := simBB;
    BB_zu        := NOT simBB;
END_IF

(* ================================================================================
   B) CONSENSI
      enable_general_ok e' una condizione PERMANENTE: se cade si interrompe subito,
      i comandi di apertura vengono tolti (i freni si chiudono a molla) e il
      setpoint di coppia va a zero.
   ================================================================================ *)
(* Per "entrambi i freni chiusi" si usa il feedback ZU, non la negazione di
   OFFEN: con un sensore rotto i due segnali non tornano coerenti *)
ok_UserLevel      := (UserLevel >= 2);                 (* 2 = livello utente minimo richiesto *)
enable_OpMode     := NOT opModeBlock;
enable_Drive      := DriveReady;
enable_Standstill := (ABS(ActRpm) <= 20.0);            (* 20 giri/min: fermo ammesso prima di aprire *)
enable_TorqueFree := (ABS(ActTorque) <= 50.0);         (* 50 unita' di coppia: carico ammesso prima di aprire *)

enable_general_ok := ServiceMode
                 AND ok_UserLevel
                 AND NotausOK
                 AND enable_OpMode
                 AND forceBlockinTest;                 (* consenso provvisorio, poi dal PILZ *)
                 (* AND enable_Drive *)                (*TODO*) (* attivare quando il segnale e' verificato *)

(* Conferma operatore con timer: scade dopo tAckValid, cosi' prima di ogni
   apertura va ridata coscientemente *)
toAck(IN := AckHazard, PT := tAckValid);
IF toAck.Q OR NOT BrakeModeActive THEN
    AckHazard := FALSE;
END_IF

(* Condizioni di transizione, usate anche come enable dei pulsanti in visu *)
enSelection := BrakeModeActive AND (act_step = 10) AND (bremseOpenLatch = 0);
                                                       (* 10 = passo pronto, 0 = nessun freno in interblocco *)

enOpen := enable_general_ok
      AND enable_Standstill
      AND enable_TorqueFree
      AND AckHazard
      AND (bremseOpenLatch = 0)                        (* punto chiave: un solo freno aperto *)
      AND (bremse_Selected <> 0)                       (* 0 = nessun freno scelto *)
      AND (mode_bremsetest <> 0)                       (* 0 = nessuna funzione scelta *)
      AND SB_zu AND BB_zu
      AND (act_step = 10);                             (* 10 = pronto *)

enTestStart := enable_general_ok
           AND (act_step = 30)                         (* 30 = un freno aperto *)
           AND (mode_bremsetest = 2)                   (* 2 = prova freni *)
           AND enable_Standstill
           AND (TorqueTarget > 0.0);

enClose := BrakeModeActive
       AND ((act_step = 20) OR (act_step = 30));       (* 20 = apertura in corso, 30 = aperto *)

(* ================================================================================
   C) VALUTAZIONE DEI COMANDI SUL FRONTE DI SALITA
   ================================================================================ *)
rtrModeOn(CLK := CmdModeOn);
rtrModeOff(CLK := CmdModeOff);
rtrSelSB(CLK := CmdSelectSB);
rtrSelBB(CLK := CmdSelectBB);
rtrSelAirgap(CLK := CmdSelectAirgap);
rtrSelBrakeTest(CLK := CmdSelectBrakeTest);
rtrOpen(CLK := CmdOpen);
rtrClose(CLK := CmdClose);
rtrTestStart(CLK := CmdTestStart);
rtrTestStop(CLK := CmdTestStop);
rtrReset(CLK := CmdReset);

(* La selezione di freno e funzione e' possibile solo con tutto chiuso e nessuna
   prova in corso *)
IF (act_step = 10) AND (bremseOpenLatch = 0) THEN      (* 10 = pronto, 0 = nessun interblocco *)
    IF rtrSelSB.Q THEN
        bremse_Selected := 1;                          (* 1 = SB, freno di stazionamento *)
        lastTestResult  := 0;                          (* 0 = esito precedente cancellato *)
    END_IF
    IF rtrSelBB.Q THEN
        bremse_Selected := 2;                          (* 2 = BB, freno di servizio *)
        lastTestResult  := 0;
    END_IF
    IF rtrSelAirgap.Q THEN
        mode_bremsetest := 1;                          (* 1 = controllo traferro *)
    END_IF
    IF rtrSelBrakeTest.Q THEN
        mode_bremsetest := 2;                          (* 2 = prova freni *)
    END_IF
END_IF

(* Normalizzazione del senso di prova a +1 / -1 *)
IF TestDirection >= 0 THEN
    Direction := 1.0;
ELSE
    Direction := -1.0;
END_IF

(* Coppia di prova del freno selezionato: si prova sempre il freno CHIUSO,
   quello che viene aperto e' l'altro *)
CASE bremse_Selected OF
    1:  TorqueTarget := LIMIT(0.0, TorqueTestSB, TorqueMax);   (* 1 = SB *)
    2:  TorqueTarget := LIMIT(0.0, TorqueTestBB, TorqueMax);   (* 2 = BB *)
ELSE
    TorqueTarget := 0.0;                                       (* 0 = nessun freno scelto *)
END_CASE

(* ================================================================================
   D) SORVEGLIANZE DURE - valgono in ogni passo del modo freni
   ================================================================================ *)
IF BrakeModeActive THEN

    (* D1 - caduta di uno dei consensi di base *)
    IF NOT enable_general_ok THEN
        IF NOT NotausOK THEN
            errorCodeBremse := 3;                      (* 3 = Notaus / Pilz non ok *)
        ELSIF NOT ServiceMode THEN
            errorCodeBremse := 1;                      (* 1 = Service Mode caduto *)
        ELSIF NOT ok_UserLevel THEN
            errorCodeBremse := 2;                      (* 2 = livello utente insufficiente *)
        ELSIF NOT enable_OpMode THEN
            errorCodeBremse := 11;                     (* 11 = modo operativo in conflitto *)
        ELSE
            errorCodeBremse := 12;                     (* 12 = inverter non pronto / consenso mancante *)
        END_IF
        act_step := 90;                                (* 90 = anomalia *)
    END_IF

    (* D2 - mai entrambi i freni aperti nello stesso momento *)
    IF SB_offen AND BB_offen THEN
        errorCodeBremse := 4;                          (* 4 = entrambi i freni aperti *)
        act_step        := 90;                         (* 90 = anomalia *)
    END_IF

    (* D3 - movimento a freno aperto fuori dalla prova freni *)
    IF (act_step = 20) OR (act_step = 30) OR (act_step = 70) THEN
                                                       (* 20 apertura, 30 aperto, 70 chiusura *)
        IF ABS(ActRpm) > RpmTripOpen THEN
            errorCodeBremse := 5;                      (* 5 = movimento a freno aperto *)
            act_step        := 90;                     (* 90 = anomalia *)
        END_IF
    END_IF

    (* D4 - sorveglianza della coppia
       - durante la prova: la coppia reale non deve superare il limite massimo
       - fuori dalla prova: con un freno aperto l'azionamento deve essere scarico *)
    IF TestRunning THEN
        IF (TorqueMax > 0.0) AND (ABS(ActTorque) > TorqueMax * 1.1) THEN
                                                       (* 1.1 = 10% di tolleranza sul limite *)
            TorqueSet       := 0.0;
            errorCodeBremse := 6;                      (* 6 = coppia reale non ammessa *)
            act_step        := 90;                     (* 90 = anomalia *)
        END_IF
    END_IF

    (* Coppia libera a freno aperto senza prova in corso: leggermente ritardata,
       cosi' la discesa di coppia dopo una prova non viene letta come anomalia *)
    toTorqueFree(IN := BrakeIsOpen AND NOT TestRunning AND NOT enable_TorqueFree,
                 PT := tMonTorqueFree);
    IF toTorqueFree.Q THEN
        TorqueSet       := 0.0;
        errorCodeBremse := 6;                          (* 6 = coppia reale non ammessa *)
        act_step        := 90;                         (* 90 = anomalia *)
    END_IF

    (* D5 - sorveglianza del tempo massimo di apertura *)
    toMaxOpen(IN := BrakeIsOpen, PT := tMaxBremseOpen);
    WarnOpenTime := toMaxOpen.Q;
    IF toMaxOpen.Q AND AutoCloseOnTimeout AND (act_step = 30) THEN   (* 30 = freno aperto *)
        errorCodeBremse := 10;                         (* 10 = tempo massimo di apertura superato *)
        act_step        := 70;                         (* 70 = chiusura *)
    END_IF
ELSE
    toMaxOpen(IN := FALSE, PT := tMaxBremseOpen);
    toTorqueFree(IN := FALSE, PT := tMonTorqueFree);
    WarnOpenTime := FALSE;
END_IF

(* ================================================================================
   E) SEQUENZA A PASSI
      I temporizzatori sono richiamati ciclicamente e indipendentemente dal passo
      attivo: cosi' si azzerano in modo sicuro appena si lascia il passo, anche
      quando l'uscita avviene per un'interruzione della sezione D.
   ================================================================================ *)
toOpen(IN := (act_step = 20), PT := tMonOpen);         (* 20 = apertura in corso     *)
toClose(IN := (act_step = 70), PT := tMonClose);       (* 70 = chiusura in corso     *)
toHold(IN := (act_step = 50), PT := tTestHoldDM);      (* 50 = mantenimento coppia   *)

CASE act_step OF

0:  (* ---- modo freni bloccato ---------------------------------------------- *)
    BrakeModeActive := FALSE;
    TestRunning     := FALSE;
    OutSB_Open      := FALSE;
    OutBB_Open      := FALSE;
    BremsentestSB   := FALSE;
    BremsentestBB   := FALSE;
    TorqueSet       := 0.0;
    RpmSet          := 0.0;
    mode_bremsetest := 0;                              (* 0 = nessuna funzione *)
    bremse_Selected := 0;                              (* 0 = nessun freno     *)
    errorCodeBremse := 0;                              (* 0 = nessuna anomalia *)

    (* L'interblocco si sblocca solo con entrambi i freni sicuramente chiusi *)
    IF SB_zu AND BB_zu THEN
        bremseOpenLatch := 0;                          (* 0 = nessun interblocco *)
    END_IF

    IF rtrModeOn.Q AND enable_general_ok AND enable_Standstill
                  AND SB_zu AND BB_zu THEN
        BrakeModeActive := TRUE;
        act_step        := 10;                         (* 10 = pronto *)
    END_IF

10: (* ---- pronto: entrambi i freni chiusi ---------------------------------- *)
    OutSB_Open    := FALSE;
    OutBB_Open    := FALSE;
    BremsentestSB := FALSE;
    BremsentestBB := FALSE;
    TestRunning   := FALSE;
    TorqueSet     := 0.0;
    RpmSet        := 0.0;

    IF SB_zu AND BB_zu THEN
        bremseOpenLatch := 0;                          (* 0 = nessun interblocco *)
    END_IF

    (* Apertura: si apre il freno che NON viene provato.
       Nel controllo del traferro si apre invece il freno selezionato stesso. *)
    IF rtrOpen.Q AND enOpen THEN
        errorCodeBremse     := 0;                      (* 0 = nessuna anomalia *)
        AckHazard           := FALSE;                  (* la conferma e' consumata *)
        SlipRev             := 0.0;
        MaxRpmInTest        := 0.0;
        TorqueReachedInTest := 0.0;
        TestPassed          := FALSE;
        TestFailed          := FALSE;

        IF mode_bremsetest = 1 THEN                    (* 1 = controllo traferro *)
            (* si apre il freno da controllare, l'altro tiene *)
            IF bremse_Selected = 1 THEN                (* 1 = SB *)
                bremseOpenLatch := 1;
            ELSE
                bremseOpenLatch := 2;                  (* 2 = BB *)
            END_IF
        ELSE
            (* prova freni: si apre l'ALTRO freno, quello selezionato tiene la coppia *)
            IF bremse_Selected = 1 THEN                (* 1 = SB selezionata -> si apre BB *)
                bremseOpenLatch := 2;
            ELSE
                bremseOpenLatch := 1;                  (* BB selezionata -> si apre SB *)
            END_IF
        END_IF
        act_step := 20;                                (* 20 = apertura in corso *)
    END_IF

    IF rtrModeOff.Q AND (bremseOpenLatch = 0) AND SB_zu AND BB_zu THEN
        act_step := 0;                                 (* 0 = modo freni bloccato *)
    END_IF

20: (* ---- apertura in corso, attesa del feedback --------------------------- *)
    (* Il comando e' attivo e il feedback viene sorvegliato.
       L'interblocco bremseOpenLatch e' gia' impostato e resta tale finche' il
       freno non viene chiuso manualmente con feedback "chiuso" presente. *)
    OutSB_Open := (bremseOpenLatch = 1);               (* 1 = SB *)
    OutBB_Open := (bremseOpenLatch = 2);               (* 2 = BB *)
    TorqueSet  := 0.0;
    RpmSet     := 0.0;

    IF ((bremseOpenLatch = 1) AND SB_offen AND NOT BB_offen)
    OR ((bremseOpenLatch = 2) AND BB_offen AND NOT SB_offen) THEN
        act_step := 30;                                (* 30 = un freno aperto *)
    ELSIF toOpen.Q THEN
        errorCodeBremse := 7;                          (* 7 = manca il feedback "aperto" *)
        act_step        := 90;                         (* 90 = anomalia *)
    END_IF

    (* Interruzione da parte dell'operatore, sempre possibile *)
    IF rtrClose.Q OR rtrTestStop.Q THEN
        act_step := 70;                                (* 70 = chiusura *)
    END_IF

30: (* ---- un freno aperto -------------------------------------------------- *)
    (* Si misura/regola il traferro oppure si avvia la prova.
       Senza prova in corso l'azionamento resta scarico. *)
    OutSB_Open    := (bremseOpenLatch = 1);            (* 1 = SB *)
    OutBB_Open    := (bremseOpenLatch = 2);            (* 2 = BB *)
    TestRunning   := FALSE;
    BremsentestSB := FALSE;
    BremsentestBB := FALSE;
    TorqueSet     := 0.0;
    RpmSet        := 0.0;

    IF rtrTestStart.Q AND enTestStart THEN
        SlipRev      := 0.0;
        MaxRpmInTest := 0.0;
        TestPassed   := FALSE;
        TestFailed   := FALSE;
        act_step     := 40;                            (* 40 = salita della coppia *)
    END_IF

    IF rtrClose.Q THEN
        act_step := 70;                                (* 70 = chiusura *)
    END_IF

40: (* ---- prova freni: salita a rampa della coppia ------------------------- *)
    (* Coppia contro il freno chiuso. Il setpoint giri resta nella finestra
       stretta di prova: se il freno tiene, l'azionamento resta fermo in
       limitazione di coppia. *)
    TestRunning   := TRUE;
    OutSB_Open    := (bremseOpenLatch = 1);            (* 1 = SB *)
    OutBB_Open    := (bremseOpenLatch = 2);            (* 2 = BB *)
    BremsentestSB := (bremse_Selected = 1);            (* SB chiusa: l'azionamento deve poter dare coppia *)
    BremsentestBB := (bremse_Selected = 2);            (* BB chiusa: idem sulla catena del freno di servizio *)

    TorqueSet := TorqueSet + TorqueRampPerSec * (tCycle / 1000.0);   (* 1000 = ms -> s *)
    IF TorqueSet > TorqueTarget THEN
        TorqueSet := TorqueTarget;
    END_IF
    RpmSet := RpmTestSetpoint * Direction;

    (* Sorveglianza dello slittamento *)
    SlipRev := SlipRev + ABS(ActRpm) / 60.0 * (tCycle / 1000.0);     (* 60 = giri/min -> giri/s *)
    IF ABS(ActRpm) > MaxRpmInTest THEN
        MaxRpmInTest := ABS(ActRpm);
    END_IF
    TorqueReachedInTest := ABS(ActTorque);

    IF (ABS(ActRpm) > RpmSlipLimit) OR (SlipRev > SlipLimitRev) THEN
        TestFailed      := TRUE;
        lastTestResult  := 2;                          (* 2 = n.i.O. *)
        errorCodeBremse := 9;                          (* 9 = il freno non tiene *)
        act_step        := 60;                         (* 60 = discesa della coppia *)
    ELSIF TorqueSet >= TorqueTarget THEN
        act_step := 50;                                (* 50 = mantenimento della coppia *)
    END_IF

    IF rtrTestStop.Q OR rtrClose.Q THEN
        act_step := 60;                                (* 60 = discesa della coppia *)
    END_IF

50: (* ---- prova freni: mantenimento della coppia --------------------------- *)
    TestRunning   := TRUE;
    OutSB_Open    := (bremseOpenLatch = 1);
    OutBB_Open    := (bremseOpenLatch = 2);
    BremsentestSB := (bremse_Selected = 1);
    BremsentestBB := (bremse_Selected = 2);
    TorqueSet     := TorqueTarget;
    RpmSet        := RpmTestSetpoint * Direction;

    SlipRev := SlipRev + ABS(ActRpm) / 60.0 * (tCycle / 1000.0);     (* 60 = giri/min -> giri/s *)
    IF ABS(ActRpm) > MaxRpmInTest THEN
        MaxRpmInTest := ABS(ActRpm);
    END_IF
    TorqueReachedInTest := ABS(ActTorque);

    IF (ABS(ActRpm) > RpmSlipLimit) OR (SlipRev > SlipLimitRev) THEN
        TestFailed      := TRUE;
        lastTestResult  := 2;                          (* 2 = n.i.O. *)
        errorCodeBremse := 9;                          (* 9 = il freno non tiene *)
        act_step        := 60;                         (* 60 = discesa della coppia *)
    ELSIF toHold.Q THEN
        TestPassed     := TRUE;
        lastTestResult := 1;                           (* 1 = i.O. *)
        act_step       := 60;                          (* 60 = discesa della coppia *)
    END_IF

    IF rtrTestStop.Q OR rtrClose.Q THEN
        act_step := 60;                                (* 60 = discesa della coppia *)
    END_IF

60: (* ---- prova freni: discesa controllata della coppia -------------------- *)
    (* Il freno resta aperto: la chiusura manuale resta comunque obbligatoria. *)
    TestRunning   := TRUE;
    OutSB_Open    := (bremseOpenLatch = 1);
    OutBB_Open    := (bremseOpenLatch = 2);
    BremsentestSB := (bremse_Selected = 1);
    BremsentestBB := (bremse_Selected = 2);
    RpmSet        := 0.0;

    TorqueSet := TorqueSet - TorqueRampPerSec * (tCycle / 1000.0);   (* 1000 = ms -> s *)
    IF TorqueSet <= 0.0 THEN
        TorqueSet     := 0.0;
        TestRunning   := FALSE;
        BremsentestSB := FALSE;
        BremsentestBB := FALSE;
        IF TestFailed THEN
            act_step := 90;      (* 90 = anomalia: esito n.i.O., va confermato con il reset *)
        ELSE
            act_step := 30;      (* 30 = freno ancora aperto, chiude l'operatore *)
        END_IF
    END_IF

70: (* ---- chiusura manuale ------------------------------------------------- *)
    (* Tolto il comando, il freno si chiude a molla. Solo con il feedback
       "chiuso" l'interblocco cade e l'altro freno torna ad essere apribile. *)
    OutSB_Open    := FALSE;
    OutBB_Open    := FALSE;
    BremsentestSB := FALSE;
    BremsentestBB := FALSE;
    TestRunning   := FALSE;
    TorqueSet     := 0.0;
    RpmSet        := 0.0;

    IF SB_zu AND BB_zu THEN
        bremseOpenLatch := 0;                          (* 0 = interblocco sbloccato *)
        IF errorCodeBremse <> 0 THEN
            act_step := 90;                            (* 90 = anomalia da confermare *)
        ELSE
            act_step := 10;                            (* 10 = pronto *)
        END_IF
    ELSIF toClose.Q THEN
        errorCodeBremse := 8;                          (* 8 = manca il feedback "chiuso" *)
        act_step        := 90;                         (* 90 = anomalia *)
    END_IF

90: (* ---- anomalia: stato sicuro ------------------------------------------- *)
    (* Nessun comando di apertura, nessuna coppia.
       L'interblocco resta finche' il freno non e' chiuso e confermato. *)
    OutSB_Open    := FALSE;
    OutBB_Open    := FALSE;
    BremsentestSB := FALSE;
    BremsentestBB := FALSE;
    TestRunning   := FALSE;
    TorqueSet     := 0.0;
    RpmSet        := 0.0;

    IF rtrReset.Q THEN
        IF SB_offen OR BB_offen THEN
            act_step := 70;                            (* 70 = prima si chiude in modo pulito *)
        ELSIF enable_general_ok THEN
            bremseOpenLatch := 0;                      (* 0 = interblocco sbloccato *)
            errorCodeBremse := 0;                      (* 0 = nessuna anomalia *)
            TestFailed      := FALSE;
            act_step        := 10;                     (* 10 = pronto *)
        ELSE
            errorCodeBremse := 0;
            BrakeModeActive := FALSE;
            act_step        := 0;                      (* 0 = modo freni bloccato *)
        END_IF
    END_IF

ELSE
    act_step := 0;                                     (* 0 = passo non valido -> stato sicuro *)
END_CASE

(* ================================================================================
   F) FORMAZIONE DELLO STATO E LIMITAZIONE DEI SETPOINT
   ================================================================================ *)
BrakeIsOpen         := BrakeModeActive
                   AND (OutSB_Open OR OutBB_Open OR SB_offen OR BB_offen);
ManualCloseRequired := (bremseOpenLatch <> 0);         (* 0 = nessun freno in interblocco *)
DriveEnableTest     := TestRunning AND enable_general_ok;

(* Doppia limitazione dei setpoint, indipendente dalla sequenza a passi *)
TorqueSet := LIMIT(0.0, TorqueSet, TorqueMax);
RpmLimit  := ABS(RpmTestSetpoint);
RpmSet    := LIMIT(-RpmLimit, RpmSet, RpmLimit);
IF NOT TestRunning THEN
    TorqueSet := 0.0;
    RpmSet    := 0.0;
END_IF

(* ================================================================================
   G) USCITE VERSO L'IMPIANTO
   ================================================================================ *)

(* --- G1: bit di bypass per la catena di consenso dei freni ---
   Durante la prova il freno provato e' CHIUSO ma l'azionamento deve poter dare
   coppia: il bypass serve solo a questo, non apre nessun freno. *)
IF NOT ServiceMode THEN                                (* senza Service Mode nessun bypass *)
    BremsentestSB := FALSE;
    BremsentestBB := FALSE;
END_IF

g_IO.Standbremsentest := BremsentestSB;
(* g_IO.Betriebsbremsentest := BremsentestBB; *)       (*TODO*) (* creare la variabile in GVL e abilitare *)

(* Catena di consenso estesa: valida solo mentre il modo freni e' attivo,
   fuori dal modo freni resta quella esistente della gestione winda. *)
IF BrakeModeActive THEN
    g_IO.AlleBremsenoffen := (g_IO.SBoffen OR BremsentestSB)
                         AND (g_IO.BBoffen OR BremsentestBB);
END_IF

(* --- G2: comando dei freni ---
   Solo nel modo freni questo PRG interviene sui freni; nel normale
   funzionamento la gestione esistente resta invariata.
   TODO: mappare sulle uscite reali di apertura dei freni: *)
IF BrakeModeActive THEN
    (* g_IO.SB_Lueften := OutSB_Open; *)               (*TODO*)
    (* g_IO.BB_Lueften := OutBB_Open; *)               (*TODO*)
    ;
END_IF

(* --- G3: setpoint dell'azionamento ---
   Nel modo freni coppia e giri sono imposti esclusivamente qui.
   Richiamare il PRG nel task DOPO la gestione winda, cosi' questi valori valgono. *)
IF BrakeModeActive THEN
    (*TODO*) (* verificare il tipo: se Solldrehmoment e' REAL togliere la conversione *)
    IO_Hauptinverter.Solldrehmoment  := REAL_TO_INT(TorqueSet);
    IO_Hauptinverter.SollRpmInverter := REAL_TO_INT(LIMIT(-RpmLimit, RpmSet, RpmLimit));
END_IF

(* ================================================================================
   H) USCITE VERSO LA VISU - led e testi di diagnostica
      I testi restano in tedesco perche' sono destinati all'operatore in impianto;
      fra parentesi la traduzione italiana.
   ================================================================================ *)
ledBrakeModeActive     := BrakeModeActive;
ledBrakeIsOpen         := BrakeIsOpen;
ledTestRunning         := TestRunning;
ledTestPassed          := (lastTestResult = 1);        (* 1 = i.O.   *)
ledTestFailed          := (lastTestResult = 2);        (* 2 = n.i.O. *)
ledManualCloseRequired := ManualCloseRequired;
ledWarnOpenTime        := WarnOpenTime;
ledSB_Selected         := (bremse_Selected = 1);       (* 1 = SB *)
ledBB_Selected         := (bremse_Selected = 2);       (* 2 = BB *)
ledModeAirgap          := (mode_bremsetest = 1);       (* 1 = controllo traferro *)
ledModeBrakeTest       := (mode_bremsetest = 2);       (* 2 = prova freni *)
ledFault               := (act_step = 90);             (* 90 = anomalia *)

CASE act_step OF
    0:   StepText := 'Bremsmodus gesperrt';                    (* modo freni bloccato              *)
    10:  StepText := 'Bereit - Bremse und Funktion waehlen';   (* pronto: scegli freno e funzione  *)
    20:  StepText := 'Bremse wird geoeffnet';                  (* apertura del freno in corso      *)
    30:  StepText := 'Bremse OFFEN - Klemmgefahr!';            (* freno APERTO - schiacciamento!   *)
    40:  StepText := 'Bremstest - Moment wird aufgebaut';      (* prova: salita della coppia       *)
    50:  StepText := 'Bremstest - Pruefmoment wird gehalten';  (* prova: coppia mantenuta          *)
    60:  StepText := 'Bremstest - Moment wird abgebaut';       (* prova: discesa della coppia      *)
    70:  StepText := 'Bremse manuell schliessen';              (* chiudere il freno manualmente    *)
    90:  StepText := 'Stoerung - quittieren';                  (* anomalia: eseguire il reset      *)
ELSE
    StepText := '';
END_CASE

CASE errorCodeBremse OF
    0:   FaultText := '';
    1:   FaultText := 'Service-Mode abgefallen';               (* Service Mode caduto              *)
    2:   FaultText := 'Userlevel zu niedrig';                  (* livello utente insufficiente     *)
    3:   FaultText := 'Not-Aus / Pilz nicht ok';               (* Notaus / Pilz non ok             *)
    4:   FaultText := 'Beide Bremsen offen - unzulaessig!';    (* entrambi i freni aperti!         *)
    5:   FaultText := 'Bewegung bei offener Bremse';           (* movimento a freno aperto         *)
    6:   FaultText := 'Unzulaessiges Moment';                  (* coppia non ammessa               *)
    7:   FaultText := 'Rueckmeldung OFFEN fehlt';              (* manca il feedback APERTO         *)
    8:   FaultText := 'Rueckmeldung ZU fehlt';                 (* manca il feedback CHIUSO         *)
    9:   FaultText := 'Bremstest n.i.O. - Bremse haelt nicht'; (* prova fallita: il freno non tiene*)
    10:  FaultText := 'Max. Offenzeit ueberschritten';         (* tempo massimo di apertura        *)
    11:  FaultText := 'Betriebsart sperrt den Bremsmodus';     (* modo operativo incompatibile     *)
    12:  FaultText := 'Umrichter nicht bereit';                (* inverter non pronto              *)
ELSE
    FaultText := 'Unbekannte Stoerung';                        (* anomalia sconosciuta             *)
END_CASE
