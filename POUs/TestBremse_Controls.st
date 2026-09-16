(* ================================================================================
   TestBremse_Controls   (PROGRAM / PRG)
   CODESYS 3.5.18.4 - Structured Text

   SCOPO (versione minima, da banco)
   ---------------------------------
   Apertura FORZATA di UN SOLO freno della winda, in Service Mode.
   Niente prova freni, niente coppia: qui si apre e si chiude, basta.

   REGOLE (da Hannes)
   ------------------
   * solo in Service Mode (chiave) e da livello utente 2
   * Notaus (Pilz) sempre attivo: se cade, il comando di apertura va via
   * winda ferma
   * un solo freno aperto per volta
   * il freno aperto va richiuso MANUALMENTE (pulsante) e deve arrivare il
     feedback "chiuso" prima che l'altro freno possa essere aperto -> brakeLatch

   SICUREZZA
   ---------
   Questo e' il livello FUNZIONALE nel PLC standard. L'interblocco vero
   (un solo freno aperto, Notaus, fermo macchina) sta nel PILZ.
   Questo PRG non bypassa nessuna sicurezza.

   STRUTTURA
   ---------
   1) IN  dall'impianto   2) IN dalla visu   3) consenso   4) interblocco
   5) comandi             6) OUT impianto    7) OUT visu
   ================================================================================ *)

PROGRAM TestBremse_Controls
VAR
    (* --- 1) INGRESSI dall'impianto: immagine locale, il PRG li LEGGE soltanto --- *)
    in_ServiceMode      : BOOL;         (* g_IO.ServiceMode        - chiave service   *)
    in_UserLevel        : INT;          (* CurrentUserLevel        - livello utente   *)
    in_NAok             : BOOL;         (* IOPilzWinde.K_NAok_VZ   - Notaus ok        *)
    in_Rpm              : REAL;         (* IO_Hauptinverter.ActualSpeed - giri/min    *)
    in_SBoffen          : BOOL;         (* g_IO.SBoffen  - feedback: SB aperta        *)
    in_BBoffen          : BOOL;         (* g_IO.BBoffen  - feedback: BB aperta        *)

    (* --- 2) INGRESSI dalla visu: pulsanti "a impulso", letti sul fronte --- *)
    CmdOpenSB           : BOOL;         (* apri freno di stazionamento (SB)           *)
    CmdOpenBB           : BOOL;         (* apri freno di servizio (BB)                *)
    CmdClose            : BOOL;         (* chiudi il freno aperto (obbligatorio)      *)

    (* --- 3) USCITE verso l'impianto: comandi di apertura --- *)
    OutSB_Open          : BOOL;         (* TRUE = SB comandata aperta                 *)
    OutBB_Open          : BOOL;         (* TRUE = BB comandata aperta                 *)

    (* --- 4) USCITE verso la visu: consensi e stato --- *)
    EnableOk            : BOOL;         (* consenso generale (permanente)             *)
    enOpenSB            : BOOL;         (* TRUE = pulsante "apri SB" ammesso          *)
    enOpenBB            : BOOL;         (* TRUE = pulsante "apri BB" ammesso          *)
    enClose             : BOOL;         (* TRUE = pulsante "chiudi" ha senso          *)
    ManualCloseRequired : BOOL;         (* TRUE = interblocco attivo, chiudi il freno *)

    (* --- 5) PARAMETRI --- *)
    RpmStandstill       : REAL := 2.0;  (* giri/min ammessi: winda ferma              *)
    MinUserLevel        : INT  := 2;    (* livello utente minimo                      *)

    (* --- 6) SIMULAZIONE FEEDBACK: solo da banco, mai in impianto --- *)
    simOn               : BOOL;         (* TRUE = feedback simulati                   *)
    simSBoffen          : BOOL;
    simBBoffen          : BOOL;

    (* --- 7) INTERNE --- *)
    brakeCmd            : INT := 0;     (* freno comandato aperto: 0 / 1 SB / 2 BB    *)
    brakeLatch          : INT := 0;     (* INTERBLOCCO: freno da richiudere 0 / 1 / 2 *)
    rtrOpenSB           : R_TRIG;
    rtrOpenBB           : R_TRIG;
    rtrClose            : R_TRIG;
END_VAR

(* ---- 1) INGRESSI -------------------------------------------------------------- *)
in_ServiceMode := g_IO.ServiceMode;
in_UserLevel   := CurrentUserLevel;                     (*TODO*) (* sorgente reale *)
in_NAok        := IOPilzWinde.K_NAok_VZ;
in_Rpm         := IO_Hauptinverter.ActualSpeed;         (*TODO*) (* nome/tipo reale *)
in_SBoffen     := g_IO.SBoffen;
in_BBoffen     := g_IO.BBoffen;

IF simOn AND in_ServiceMode THEN
    in_SBoffen := simSBoffen;
    in_BBoffen := simBBoffen;
END_IF

(* ---- 2) CONSENSO GENERALE ----------------------------------------------------- *)
(* Condizione PERMANENTE: se cade, il comando di apertura va via e il freno
   si chiude a molla (sezione 5). *)
EnableOk := in_ServiceMode
        AND (in_UserLevel >= MinUserLevel)
        AND in_NAok
        AND (ABS(in_Rpm) <= RpmStandstill);

(* ---- 3) INTERBLOCCO ----------------------------------------------------------- *)
(* Si sblocca solo con il comando tolto E i due feedback "aperto" caduti:
   e' questa la chiusura manuale obbligatoria. *)
IF (brakeCmd = 0) AND NOT in_SBoffen AND NOT in_BBoffen THEN
                                        (*TODO*) (* se esistono SBzu/BBzu usare quelli *)
    brakeLatch := 0;
END_IF

(* ---- 4) CONSENSI DEI PULSANTI (li legge la visu) ------------------------------ *)
(* Si apre solo con: consenso ok, nessun interblocco, tutti e due i freni chiusi *)
enOpenSB := EnableOk AND (brakeLatch = 0) AND NOT in_SBoffen AND NOT in_BBoffen;
enOpenBB := EnableOk AND (brakeLatch = 0) AND NOT in_SBoffen AND NOT in_BBoffen;
enClose  := (brakeCmd <> 0);

(* ---- 5) COMANDI SUL FRONTE DI SALITA ------------------------------------------ *)
rtrOpenSB(CLK := CmdOpenSB);
rtrOpenBB(CLK := CmdOpenBB);
rtrClose(CLK := CmdClose);

IF rtrOpenSB.Q AND enOpenSB THEN
    brakeCmd   := 1;                    (* 1 = SB *)
    brakeLatch := 1;
END_IF

IF rtrOpenBB.Q AND enOpenBB THEN
    brakeCmd   := 2;                    (* 2 = BB *)
    brakeLatch := 2;
END_IF

IF rtrClose.Q THEN
    brakeCmd := 0;                      (* comando tolto -> il freno chiude a molla *)
END_IF

(* Sorveglianza permanente: consenso caduto oppure entrambi i freni aperti *)
IF NOT EnableOk OR (in_SBoffen AND in_BBoffen) THEN
    brakeCmd := 0;
END_IF

(* ---- 6) USCITE VERSO L'IMPIANTO ----------------------------------------------- *)
OutSB_Open := (brakeCmd = 1);
OutBB_Open := (brakeCmd = 2);

(* g_IO.SB_Lueften := OutSB_Open; *)                    (*TODO*) (* uscita reale SB *)
(* g_IO.BB_Lueften := OutBB_Open; *)                    (*TODO*) (* uscita reale BB *)

(* ---- 7) USCITA VERSO LA VISU -------------------------------------------------- *)
ManualCloseRequired := (brakeLatch <> 0);
