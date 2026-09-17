(* ================================================================================
   TestBremse_Controls (PRG) - CODESYS 3.5.18.4

   Comando manuale dei due freni winda in Service Mode.
   SB = Standbremse (stazionamento), BB = Betriebsbremse (servizio).

   Come funziona:
   - I feedback g_IO.SBoffen / g_IO.BBoffen dicono lo stato reale: TRUE = APERTO.
   - Entrando nel modo i comandi interni vengono allineati ai feedback: un freno
     gia' aperto resta aperto ed e' l'operatore a doverlo chiudere.
   - Si apre un freno solo se l'altro e' chiuso (comando E feedback).
   - Chiudere e' sempre ammesso e non ha condizioni.
   - Nessun timer: apertura e chiusura seguono subito il comando.
   - I comandi dalla visu sono impulsi: il PRG li esegue e li azzera, quindi non
     possono restare attivi insieme. Precedenze: OFF prima di ON, CHIUDI prima di APRI.
   - Verso la Pilz esiste un solo segnale per freno: TRUE = apri, FALSE = chiudi
     (il freno chiude a molla quando cade il comando).
   ================================================================================ *)

PROGRAM TestBremse_Controls
VAR
    (* ---- comandi dalla visu (impulso, azzerati dal PRG) ---- *)
    CmdTestOn           : BOOL;         (* attiva il modo *)
    CmdTestOff          : BOOL;         (* esci dal modo *)
    CmdOpenSB           : BOOL;         (* apri SB *)
    CmdCloseSB          : BOOL;         (* chiudi SB *)
    CmdOpenBB           : BOOL;         (* apri BB *)
    CmdCloseBB          : BOOL;         (* chiudi BB *)

    (* ---- uscite ---- *)
    ManualTestBremse    : BOOL;         (* modo attivo *)
    OutSB_Open          : BOOL;         (* TRUE = apri SB, FALSE = chiudi SB *)
    OutBB_Open          : BOOL;         (* TRUE = apri BB, FALSE = chiudi BB *)

    (* ---- stato per la visu ---- *)
    EnableOk            : BOOL;         (* consenso generale, permanente *)
    enTestOn            : BOOL;         (* pulsante "attiva modo" ammesso *)
    enTestOff           : BOOL;         (* pulsante "esci dal modo" ammesso *)
    enOpenSB            : BOOL;         (* pulsante "apri SB" ammesso *)
    enCloseSB           : BOOL;         (* pulsante "chiudi SB" ammesso *)
    enOpenBB            : BOOL;         (* pulsante "apri BB" ammesso *)
    enCloseBB           : BOOL;         (* pulsante "chiudi BB" ammesso *)
    brakeOpenFb         : INT := 0;     (* feedback: 0 nessuno / 1 SB / 2 BB / 3 entrambi *)
    SBclosed            : BOOL;         (* SB chiusa: non comandata e feedback chiuso *)
    BBclosed            : BOOL;         (* BB chiusa: non comandata e feedback chiuso *)
    BothClosedOk        : BOOL;         (* interblocco libero: tutti e due chiusi *)
    BrakeOpenOk         : BOOL;         (* aperto da me e feedback "aperto" presente *)
    ManualCloseRequired : BOOL;         (* nel modo un freno risulta aperto *)
    FaultBothOpen       : BOOL;         (* anomalia: aperti tutti e due *)
    WarnNoFeedback      : BOOL;         (* comandato aperto ma feedback ancora chiuso *)
    WarnOpenExtern      : BOOL;         (* aperto senza comando di questa pagina *)

    (* ---- parametri ---- *)
    RpmStandstill       : REAL := 2.0;  (* giri/min ammessi: winda ferma *)
    TorqueFreeLimit     : REAL := 50.0; (* coppia reale ammessa: azionamento scarico *)
    MinUserLevel        : DINT := 2;    (* livello utente minimo *)

    (* ---- interne ---- *)
    cmdSB_Open          : BOOL;         (* comando interno: SB aperta *)
    cmdBB_Open          : BOOL;         (* comando interno: BB aperta *)
END_VAR

(* --- consenso generale: se cade, i comandi di apertura vanno via subito --- *)
EnableOk := g_IO.ServiceMode
        AND (CurrentUserLevel >= MinUserLevel)
        AND IOPilzWinde.K_NAok_VZ
        AND (ABS(IO_Hauptinverter.ActualSpeed) <= RpmStandstill)
        AND (ABS(IO_Hauptinverter.ActualDM) <= TorqueFreeLimit);

(* --- stato reale dai feedback --- *)
IF g_IO.SBoffen AND g_IO.BBoffen THEN
    brakeOpenFb := 3;
ELSIF g_IO.SBoffen THEN
    brakeOpenFb := 1;
ELSIF g_IO.BBoffen THEN
    brakeOpenFb := 2;
ELSE
    brakeOpenFb := 0;
END_IF
FaultBothOpen := (brakeOpenFb = 3);

SBclosed := NOT cmdSB_Open AND NOT g_IO.SBoffen;
BBclosed := NOT cmdBB_Open AND NOT g_IO.BBoffen;

(* --- modo: OFF ha la precedenza su ON, entrando i comandi seguono i feedback --- *)
IF CmdTestOff OR NOT g_IO.ServiceMode THEN
    ManualTestBremse := FALSE;
ELSIF CmdTestOn AND EnableOk AND NOT ManualTestBremse THEN
    ManualTestBremse := TRUE;
    cmdSB_Open       := g_IO.SBoffen;
    cmdBB_Open       := g_IO.BBoffen;
END_IF
CmdTestOn  := FALSE;
CmdTestOff := FALSE;

(* --- apri / chiudi: CHIUDI ha la precedenza, aprire solo con l'altro freno chiuso --- *)
IF ManualTestBremse THEN
    IF CmdCloseSB THEN
        cmdSB_Open := FALSE;
    ELSIF CmdOpenSB AND EnableOk AND BBclosed THEN
        cmdSB_Open := TRUE;
    END_IF

    IF CmdCloseBB THEN
        cmdBB_Open := FALSE;
    ELSIF CmdOpenBB AND EnableOk AND SBclosed THEN
        cmdBB_Open := TRUE;
    END_IF
END_IF
CmdOpenSB  := FALSE;
CmdCloseSB := FALSE;
CmdOpenBB  := FALSE;
CmdCloseBB := FALSE;

(* --- modo non attivo, consenso caduto o due freni aperti: tutto chiuso --- *)
IF NOT ManualTestBremse OR NOT EnableOk OR FaultBothOpen THEN
    cmdSB_Open := FALSE;
    cmdBB_Open := FALSE;
END_IF

(* --- stato aggiornato per la visu --- *)
SBclosed     := NOT cmdSB_Open AND NOT g_IO.SBoffen;
BBclosed     := NOT cmdBB_Open AND NOT g_IO.BBoffen;
BothClosedOk := SBclosed AND BBclosed;

BrakeOpenOk         := (cmdSB_Open AND g_IO.SBoffen) OR (cmdBB_Open AND g_IO.BBoffen);
WarnNoFeedback      := (cmdSB_Open AND NOT g_IO.SBoffen) OR (cmdBB_Open AND NOT g_IO.BBoffen);
WarnOpenExtern      := ManualTestBremse AND ((g_IO.SBoffen AND NOT cmdSB_Open) OR (g_IO.BBoffen AND NOT cmdBB_Open));
ManualCloseRequired := ManualTestBremse AND (brakeOpenFb <> 0);

enTestOn  := EnableOk AND NOT ManualTestBremse;
enTestOff := ManualTestBremse;
enOpenSB  := ManualTestBremse AND EnableOk AND BBclosed AND NOT cmdSB_Open;
enOpenBB  := ManualTestBremse AND EnableOk AND SBclosed AND NOT cmdBB_Open;
enCloseSB := ManualTestBremse AND (cmdSB_Open OR g_IO.SBoffen);
enCloseBB := ManualTestBremse AND (cmdBB_Open OR g_IO.BBoffen);

(* --- uscite: fuori dal modo i comandi sono gia' a FALSE --- *)
OutSB_Open := cmdSB_Open;
OutBB_Open := cmdBB_Open;

IOPilzWinde.Out_SBtest           := OutSB_Open;
IOPilzWinde.Out_BBtest           := OutBB_Open;
IOPilzWinde.Out_ManualTestBremse := ManualTestBremse;
