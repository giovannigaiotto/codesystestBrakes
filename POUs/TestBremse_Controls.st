(* ================================================================================
   TestBremse_Controls   (PROGRAM / PRG)
   CODESYS 3.5.18.4 - Structured Text

   Zweck
   -----
   Bediengefuehrte und verriegelte Bedienung der beiden Windenbremsen im
   Service-Mode:
     1) Lueftspaltkontrolle  -> eine Bremse oeffnen, die andere haelt die Winde
     2) Bremstest            -> Moment gegen die geschlossene Bremse aufbauen
                                und auf Schlupf ueberwachen

   Grundregeln (Vorgabe Projektleitung)
   ------------------------------------
   * Nur im Service-Mode (Schluesselschalter) und ab Userlevel 2 bedienbar
   * Not-Aus bleibt jederzeit aktiv und ist Freigabebedingung
   * Es darf immer nur EINE Bremse offen sein
   * Eine geoeffnete Bremse muss MANUELL wieder geschlossen werden,
     bevor die andere Bremse geoeffnet werden kann (Verriegelung iBremseOffenLatch)
   * Drehzahl und Moment werden dauernd ueberwacht; bei Bewegung bzw.
     unzulaessigem Moment werden Sollwerte gesperrt und die Bremsen geschlossen

   ACHTUNG - SICHERHEITSTECHNIK
   ----------------------------
   Diese Schrittkette ist die FUNKTIONALE Verriegelung in der Standard-SPS.
   Die sicherheitsgerichtete Verriegelung (nur eine Bremse offen, Not-Aus,
   Stillstands-/Drehzahlwaechter, sichere Momentbegrenzung) muss in der
   Pilz-Sicherheitssteuerung realisiert und dort auch bewertet werden.
   Diese SPS darf keine Sicherheitsfunktion ueberbruecken.

   Einbindung
   ----------
   * PRG in der Task NACH der normalen Windensteuerung aufrufen, damit die hier
     erzwungenen Sollwerte (0 / begrenzt) die letzten Schreibzugriffe sind.
   * Der alte Code-Block
         IF g_io.Standbremsentest THEN
             IO_Hauptinverter.Solldrehmoment := DMStandbremsentest; ...
     entfaellt - die Sollwertvorgabe erfolgt jetzt ausschliesslich hier.
   * g_IO.Standbremsentest ist jetzt reines Bypass-Bit fuer die Bremsen-
     Freigabekette (SB ist beim Test ZU, Antrieb muss trotzdem Moment geben).
     Fuer den Betriebsbremsentest ist in der GVL zusaetzlich
         Betriebsbremsentest : BOOL;
     anzulegen und die Freigabekette zu erweitern:
         g_IO.AlleBremsenoffen := (g_IO.SBoffen OR g_IO.Standbremsentest)
                              AND (g_IO.BBoffen OR g_IO.Betriebsbremsentest);
   * Die mit TODO markierten Zeilen sind die Schnittstellen zur Anlage und
     muessen einmalig auf die realen Variablennamen/Typen angepasst werden.
   ================================================================================ *)

PROGRAM TestBremse_Controls
VAR CONSTANT
    (* ---- Schrittkette ---- *)
    SCHRITT_GESPERRT        : INT := 0;    (* Bremsmodus nicht angewaehlt          *)
    SCHRITT_BEREIT          : INT := 10;   (* Modus aktiv, alle Bremsen zu         *)
    SCHRITT_OEFFNEN         : INT := 20;   (* Oeffnungsbefehl, warten auf RM offen *)
    SCHRITT_OFFEN           : INT := 30;   (* eine Bremse offen (Lueftspalt)       *)
    SCHRITT_TEST_RAMPE      : INT := 40;   (* Moment rampenfoermig aufbauen        *)
    SCHRITT_TEST_HALTEN     : INT := 50;   (* Pruefmoment halten, Schlupf pruefen  *)
    SCHRITT_TEST_ABBAU      : INT := 60;   (* Moment abbauen                       *)
    SCHRITT_SCHLIESSEN      : INT := 70;   (* manuelles Schliessen (Pflicht)       *)
    SCHRITT_STOERUNG        : INT := 90;   (* Stoerung, quittieren erforderlich    *)

    (* ---- Bremsenauswahl ---- *)
    BREMSE_KEINE            : INT := 0;
    BREMSE_SB               : INT := 1;    (* Standbremse    *)
    BREMSE_BB               : INT := 2;    (* Betriebsbremse *)

    (* ---- Funktionsauswahl ---- *)
    FUNKTION_KEINE          : INT := 0;
    FUNKTION_LUEFTSPALT     : INT := 1;    (* nur oeffnen, KEIN Moment *)
    FUNKTION_BREMSTEST      : INT := 2;    (* Moment gegen geschlossene Bremse *)

    (* ---- Stoercodes ---- *)
    ERR_KEIN                : INT := 0;
    ERR_SERVICEMODE         : INT := 1;    (* Service-Mode abgefallen           *)
    ERR_USERLEVEL           : INT := 2;    (* Userlevel < 2                     *)
    ERR_NOTAUS              : INT := 3;    (* Not-Aus / Pilz nicht ok           *)
    ERR_BEIDE_OFFEN         : INT := 4;    (* beide Bremsen gleichzeitig offen  *)
    ERR_BEWEGUNG            : INT := 5;    (* Drehzahl ausserhalb Fenster       *)
    ERR_MOMENT              : INT := 6;    (* Istmoment unzulaessig             *)
    ERR_RM_OEFFNEN          : INT := 7;    (* Rueckmeldung "offen" fehlt        *)
    ERR_RM_SCHLIESSEN       : INT := 8;    (* Rueckmeldung "zu" fehlt           *)
    ERR_TEST_NOK            : INT := 9;    (* Bremse haelt Pruefmoment nicht    *)
    ERR_ZEIT_OFFEN          : INT := 10;   (* max. Offenzeit ueberschritten     *)
    ERR_BETRIEBSART         : INT := 11;   (* Normalbetrieb/Sim/IBN aktiv       *)
    ERR_ANTRIEB             : INT := 12;   (* Umrichter nicht bereit / Stoerung *)

    MIN_USERLEVEL           : INT := 2;    (* Vorgabe: Nutzerlevel 2            *)
    ZYKLUS_MS               : REAL := 10.0;(* TODO: an Taskzykluszeit anpassen   *)
END_VAR

VAR
    (* ============================================================
       1) Bedienung (Visu schreibt direkt auf diese Variablen)
          Buttons als "Variable tasten" (FALSE->TRUE) projektieren,
          Auswertung erfolgt flankengetriggert.
          Button-Sperre in der Visu bleibt zusaetzlich bestehen:
          ((IOPilzWinde.K_NAok_VZ) AND (g_IO.ServiceMode)
           AND (CurrentUserLevel>=2)) = FALSE
       ============================================================ *)
    xBedienModusEin         : BOOL;   (* Bremsmodus anwaehlen                    *)
    xBedienModusAus         : BOOL;   (* Bremsmodus verlassen                    *)
    xWahlSB                 : BOOL;   (* Standbremse anwaehlen                   *)
    xWahlBB                 : BOOL;   (* Betriebsbremse anwaehlen                *)
    xWahlLueftspalt         : BOOL;   (* Funktion Lueftspaltkontrolle            *)
    xWahlBremstest          : BOOL;   (* Funktion Bremstest                      *)
    xQuittungGefahr         : BOOL;   (* Checkbox: Klemmgefahr / Winde entlastet *)
    xBedienOeffnen          : BOOL;   (* angewaehlte Bremse oeffnen              *)
    xBedienSchliessen       : BOOL;   (* Bremse manuell schliessen (Pflicht!)    *)
    xBedienTestStart        : BOOL;   (* Bremstest starten                       *)
    xBedienTestStop         : BOOL;   (* Bremstest abbrechen                     *)
    xBedienQuittieren       : BOOL;   (* Stoerung quittieren                     *)
    iTestRichtung           : INT := 1; (* +1 = Zugrichtung, -1 = Gegenrichtung  *)

    (* ============================================================
       2) Parameter (online einstellbar, ggf. als PERSISTENT fuehren)
          Alle Werte anlagenspezifisch parametrieren!
       ============================================================ *)
    rRpmStillstand          : REAL := 2.0;    (* U/min: Stillstandsfenster fuer Freigabe   *)
    rRpmAbschaltung         : REAL := 5.0;    (* U/min: Bewegung bei offener Bremse -> Halt*)
    rRpmSchlupfGrenze       : REAL := 3.0;    (* U/min: zul. Schlupf im Bremstest          *)
    rRpmSollTest            : REAL := 5.0;    (* U/min: Drehzahlsollwert im Bremstest      *)
    rSchlupfGrenzeUmdr      : REAL := 0.05;   (* Umdr.: zul. Verdrehung im Bremstest       *)
    rDMStillstand           : REAL := 5.0;    (* zul. Istmoment vor dem Oeffnen            *)
    rDMTest_SB              : REAL := 0.0;    (* Pruefmoment Standbremse    -> parametrieren*)
    rDMTest_BB              : REAL := 0.0;    (* Pruefmoment Betriebsbremse -> parametrieren*)
    rDMMaxZulaessig         : REAL := 0.0;    (* harte Obergrenze Sollmoment-> parametrieren*)
    rRampeDMproSek          : REAL := 10.0;   (* Momentaufbau je Sekunde                   *)
    tHaltezeitTest          : TIME := T#5S;   (* Haltezeit Pruefmoment                     *)
    tUeberwOeffnen          : TIME := T#3S;   (* Zeit bis RM "offen" erwartet wird         *)
    tUeberwSchliessen       : TIME := T#3S;   (* Zeit bis RM "zu" erwartet wird            *)
    tMaxOffen               : TIME := T#30M;  (* max. Zeit mit offener Bremse              *)
    tQuittungGueltig        : TIME := T#60S;  (* Gueltigkeit der Gefahren-Quittung         *)
    tUeberwMomentfrei       : TIME := T#1S;   (* Verzoegerung Ueberwachung "momentfrei"     *)
    xAutoCloseBeiZeit       : BOOL := FALSE;  (* TRUE: nach tMaxOffen zwangsweise schliessen*)

    (* ============================================================
       3) Istwerte / Rueckmeldungen (Abbild, Zuweisung im Abschnitt A)
       ============================================================ *)
    rIstRpm                 : REAL;
    rIstDM                  : REAL;
    iUserlevel              : INT;
    xSB_Ist_Offen           : BOOL;
    xSB_Ist_Zu              : BOOL;
    xBB_Ist_Offen           : BOOL;
    xBB_Ist_Zu              : BOOL;
    xServiceMode            : BOOL;
    xNotAusOK               : BOOL;
    xAntriebBereit          : BOOL;
    xSperreBetriebsart      : BOOL;   (* IBN / Simulation / Normalbetrieb aktiv *)

    (* ============================================================
       4) Freigaben / Status
       ============================================================ *)
    xFrg_ServiceMode        : BOOL;
    xFrg_Userlevel          : BOOL;
    xFrg_NotAus             : BOOL;
    xFrg_Betriebsart        : BOOL;
    xFrg_Antrieb            : BOOL;
    xFrg_Stillstand         : BOOL;
    xFrg_MomentFrei         : BOOL;
    xFrg_Gesamt             : BOOL;   (* Dauerbedingung waehrend des Modus *)
    xFrg_Oeffnen            : BOOL;   (* Transitionsbedingung "oeffnen"    *)
    xFrg_TestStart          : BOOL;   (* Transitionsbedingung "Test start" *)

    (* ---- Hauptstatus / Ausgaenge des PRG ---- *)
    xTestBremseAktiv        : BOOL;   (* Bremsmodus aktiv -> Normalbetrieb sperren *)
    xTestBremseOffen        : BOOL;   (* eine Bremse ist geoeffnet                 *)
    xBremstestLaeuft        : BOOL;
    xBremstestOK            : BOOL;
    xBremstestNOK           : BOOL;
    xManuellSchliessenNoetig: BOOL;   (* Verriegelung bis manuell geschlossen      *)
    xBefehlSB_Oeffnen       : BOOL;   (* Ansteuerung Standbremse lueften           *)
    xBefehlBB_Oeffnen       : BOOL;   (* Ansteuerung Betriebsbremse lueften        *)
    xBypassSB               : BOOL;   (* -> g_IO.Standbremsentest                  *)
    xBypassBB               : BOOL;   (* -> g_IO.Betriebsbremsentest (neu in GVL)  *)
    xAntriebFreigabeTest    : BOOL;   (* Umrichterfreigabe nur waehrend Bremstest  *)

    iSchritt                : INT := 0;
    iBremseAngewaehlt       : INT := 0;
    iBremseOffenLatch       : INT := 0;  (* Kernverriegelung: welche Bremse ist/war offen *)
    iFunktion               : INT := 0;
    iStoercode              : INT := 0;
    iLetztesTestergebnis    : INT := 0;  (* 0=kein, 1=i.O., 2=n.i.O. *)

    (* ---- Sollwerte Antrieb ---- *)
    rDM_Soll                : REAL;      (* Momentgrenze/-sollwert, gerampt *)
    rDM_Ziel                : REAL;      (* Pruefmoment der angewaehlten Bremse *)
    rRpm_Soll               : REAL;
    rRpm_Grenze             : REAL;
    rRichtung               : REAL := 1.0;   (* +1.0 / -1.0 aus iTestRichtung *)

    (* ---- Messwerte Bremstest ---- *)
    rSchlupfUmdr            : REAL;      (* aufintegrierte Verdrehung im Test *)
    rMaxRpmImTest           : REAL;
    rDM_ErreichtImTest      : REAL;

    (* ---- Flanken ---- *)
    rtModusEin              : R_TRIG;
    rtModusAus              : R_TRIG;
    rtWahlSB                : R_TRIG;
    rtWahlBB                : R_TRIG;
    rtWahlLueftspalt        : R_TRIG;
    rtWahlBremstest         : R_TRIG;
    rtOeffnen               : R_TRIG;
    rtSchliessen            : R_TRIG;
    rtTestStart             : R_TRIG;
    rtTestStop              : R_TRIG;
    rtQuittieren            : R_TRIG;

    (* ---- Zeiten ---- *)
    tonOeffnen              : TON;
    tonSchliessen           : TON;
    tonHaltezeit            : TON;
    tonMaxOffen             : TON;
    tonQuittung             : TON;
    tonMomentfrei           : TON;

    (* ---- Diagnose fuer die Visu ---- *)
    sSchrittText            : STRING(80);
    sStoerText              : STRING(80);
    xWarnungZeitOffen       : BOOL;
END_VAR

(* ================================================================================
   A) SCHNITTSTELLE ZUR ANLAGE - Istwerte einlesen
      TODO: Namen/Typen einmalig gegen das Projekt pruefen
   ================================================================================ *)
xServiceMode  := g_IO.ServiceMode;
xNotAusOK     := IOPilzWinde.K_NAok_VZ;                  (* Not-Aus-Kreis ok, verzoegert *)
iUserlevel    := CurrentUserLevel;                       (*TODO*) (* Quelle Userlevel pruefen *)

xSB_Ist_Offen := g_IO.SBoffen;
xSB_Ist_Zu    := NOT g_IO.SBoffen;                       (*TODO*) (* falls eigene RM "SBzu" vorhanden, hier eintragen *)
xBB_Ist_Offen := g_IO.BBoffen;
xBB_Ist_Zu    := g_IO.BBzu;

rIstRpm       := INT_TO_REAL(IO_Hauptinverter.IstRpmInverter);   (*TODO*) (* Name/Typ Drehzahl-Istwert *)
rIstDM        := IO_Hauptinverter.Istdrehmoment;                 (*TODO*) (* Name/Typ Moment-Istwert   *)
xAntriebBereit:= IO_Hauptinverter.Bereit;                        (*TODO*) (* Bereit-/Stoermeldung      *)

(* Betriebsarten, die den Bremsmodus ausschliessen *)
xSperreBetriebsart := App_Winde.inbetriebnahme;          (*TODO*) (* ggf. OR simbremsen OR Fahrbefehl *)

(* ================================================================================
   B) FREIGABEN
      xFrg_Gesamt ist Dauerbedingung: faellt sie weg, wird sofort abgebrochen,
      die Bremsbefehle werden weggenommen (Bremsen fallen federbetaetigt zu)
      und der Momentsollwert wird auf 0 gesetzt.
   ================================================================================ *)
xFrg_ServiceMode := xServiceMode;
xFrg_Userlevel   := (iUserlevel >= MIN_USERLEVEL);       (* ggf. zusaetzlich AND PLC_PRG.userlevel3 *)
xFrg_NotAus      := xNotAusOK;
xFrg_Betriebsart := NOT xSperreBetriebsart;
xFrg_Antrieb     := xAntriebBereit;
xFrg_Stillstand  := (ABS(rIstRpm) <= rRpmStillstand);
xFrg_MomentFrei  := (ABS(rIstDM)  <= rDMStillstand);

xFrg_Gesamt := xFrg_ServiceMode
           AND xFrg_Userlevel
           AND xFrg_NotAus
           AND xFrg_Betriebsart
           AND xFrg_Antrieb;

(* Gefahren-Quittung laeuft ab -> vor jedem Oeffnen bewusst neu bestaetigen *)
tonQuittung(IN := xQuittungGefahr, PT := tQuittungGueltig);
IF tonQuittung.Q OR NOT xTestBremseAktiv THEN
    xQuittungGefahr := FALSE;
END_IF

(* Transitionsbedingungen fuer die Visu (Button-Enable) *)
xFrg_Oeffnen := xFrg_Gesamt
            AND xFrg_Stillstand
            AND xFrg_MomentFrei
            AND xQuittungGefahr
            AND (iBremseOffenLatch = BREMSE_KEINE)      (* Kernforderung: nur eine Bremse *)
            AND (iBremseAngewaehlt <> BREMSE_KEINE)
            AND (iFunktion <> FUNKTION_KEINE)
            AND xSB_Ist_Zu AND xBB_Ist_Zu
            AND (iSchritt = SCHRITT_BEREIT);

xFrg_TestStart := xFrg_Gesamt
              AND (iSchritt = SCHRITT_OFFEN)
              AND (iFunktion = FUNKTION_BREMSTEST)
              AND xFrg_Stillstand
              AND (rDM_Ziel > 0.0);

(* ================================================================================
   C) FLANKENAUSWERTUNG BEDIENUNG
   ================================================================================ *)
rtModusEin(CLK := xBedienModusEin);
rtModusAus(CLK := xBedienModusAus);
rtWahlSB(CLK := xWahlSB);
rtWahlBB(CLK := xWahlBB);
rtWahlLueftspalt(CLK := xWahlLueftspalt);
rtWahlBremstest(CLK := xWahlBremstest);
rtOeffnen(CLK := xBedienOeffnen);
rtSchliessen(CLK := xBedienSchliessen);
rtTestStart(CLK := xBedienTestStart);
rtTestStop(CLK := xBedienTestStop);
rtQuittieren(CLK := xBedienQuittieren);

(* Anwahl Bremse/Funktion nur solange nichts offen und kein Test laeuft *)
IF (iSchritt = SCHRITT_BEREIT) AND (iBremseOffenLatch = BREMSE_KEINE) THEN
    IF rtWahlSB.Q THEN
        iBremseAngewaehlt := BREMSE_SB;
        iLetztesTestergebnis := 0;
    END_IF
    IF rtWahlBB.Q THEN
        iBremseAngewaehlt := BREMSE_BB;
        iLetztesTestergebnis := 0;
    END_IF
    IF rtWahlLueftspalt.Q THEN
        iFunktion := FUNKTION_LUEFTSPALT;
    END_IF
    IF rtWahlBremstest.Q THEN
        iFunktion := FUNKTION_BREMSTEST;
    END_IF
END_IF

(* Testrichtung auf +1 / -1 normieren *)
IF iTestRichtung >= 0 THEN
    rRichtung := 1.0;
ELSE
    rRichtung := -1.0;
END_IF

(* Pruefmoment der angewaehlten Bremse: getestet wird immer die GESCHLOSSENE
   Bremse - geoeffnet wird die jeweils andere.                                  *)
CASE iBremseAngewaehlt OF
    BREMSE_SB:  rDM_Ziel := LIMIT(0.0, rDMTest_SB, rDMMaxZulaessig);
    BREMSE_BB:  rDM_Ziel := LIMIT(0.0, rDMTest_BB, rDMMaxZulaessig);
ELSE
    rDM_Ziel := 0.0;
END_CASE

(* ================================================================================
   D) HARTE UEBERWACHUNGEN - gelten in jedem Schritt des Bremsmodus
   ================================================================================ *)
IF xTestBremseAktiv THEN

    (* D1 - Grundfreigaben weggefallen *)
    IF NOT xFrg_Gesamt THEN
        IF NOT xFrg_NotAus THEN
            iStoercode := ERR_NOTAUS;
        ELSIF NOT xFrg_ServiceMode THEN
            iStoercode := ERR_SERVICEMODE;
        ELSIF NOT xFrg_Userlevel THEN
            iStoercode := ERR_USERLEVEL;
        ELSIF NOT xFrg_Betriebsart THEN
            iStoercode := ERR_BETRIEBSART;
        ELSE
            iStoercode := ERR_ANTRIEB;
        END_IF
        iSchritt := SCHRITT_STOERUNG;
    END_IF

    (* D2 - niemals beide Bremsen gleichzeitig offen *)
    IF xSB_Ist_Offen AND xBB_Ist_Offen THEN
        iStoercode := ERR_BEIDE_OFFEN;
        iSchritt   := SCHRITT_STOERUNG;
    END_IF

    (* D3 - Bewegung bei offener Bremse ausserhalb des Bremstests *)
    IF (iSchritt = SCHRITT_OEFFNEN) OR (iSchritt = SCHRITT_OFFEN) OR (iSchritt = SCHRITT_SCHLIESSEN) THEN
        IF ABS(rIstRpm) > rRpmAbschaltung THEN
            iStoercode := ERR_BEWEGUNG;
            iSchritt   := SCHRITT_STOERUNG;
        END_IF
    END_IF

    (* D4 - Momentueberwachung
       - waehrend des Bremstests: Istmoment darf die Obergrenze nicht ueberschreiten
       - ausserhalb des Bremstests: bei offener Bremse muss der Antrieb momentfrei sein *)
    IF xBremstestLaeuft THEN
        IF (rDMMaxZulaessig > 0.0) AND (ABS(rIstDM) > rDMMaxZulaessig * 1.1) THEN
            rDM_Soll   := 0.0;
            iStoercode := ERR_MOMENT;
            iSchritt   := SCHRITT_STOERUNG;
        END_IF
    END_IF

    (* Momentfreiheit bei offener Bremse ohne laufenden Test - kurz verzoegert,
       damit der Momentabbau nach einem Bremstest nicht als Stoerung gilt *)
    tonMomentfrei(IN := xTestBremseOffen AND NOT xBremstestLaeuft AND NOT xFrg_MomentFrei,
                  PT := tUeberwMomentfrei);
    IF tonMomentfrei.Q THEN
        rDM_Soll   := 0.0;
        iStoercode := ERR_MOMENT;
        iSchritt   := SCHRITT_STOERUNG;
    END_IF

    (* D5 - Ueberwachung der maximalen Offenzeit *)
    tonMaxOffen(IN := xTestBremseOffen, PT := tMaxOffen);
    xWarnungZeitOffen := tonMaxOffen.Q;
    IF tonMaxOffen.Q AND xAutoCloseBeiZeit AND (iSchritt = SCHRITT_OFFEN) THEN
        iStoercode := ERR_ZEIT_OFFEN;
        iSchritt   := SCHRITT_SCHLIESSEN;
    END_IF
ELSE
    tonMaxOffen(IN := FALSE, PT := tMaxOffen);
    tonMomentfrei(IN := FALSE, PT := tUeberwMomentfrei);
    xWarnungZeitOffen := FALSE;
END_IF

(* ================================================================================
   E) SCHRITTKETTE
      Die Zeitglieder werden zyklisch und unabhaengig vom aktiven Schritt
      aufgerufen. Dadurch werden sie beim Verlassen eines Schrittes sicher
      zurueckgesetzt (auch bei einem Abbruch ueber Abschnitt D).
   ================================================================================ *)
tonOeffnen(IN := (iSchritt = SCHRITT_OEFFNEN),     PT := tUeberwOeffnen);
tonSchliessen(IN := (iSchritt = SCHRITT_SCHLIESSEN), PT := tUeberwSchliessen);
tonHaltezeit(IN := (iSchritt = SCHRITT_TEST_HALTEN), PT := tHaltezeitTest);

CASE iSchritt OF

(* ---------------------------------------------------------------- *)
SCHRITT_GESPERRT:
    xTestBremseAktiv  := FALSE;
    xBremstestLaeuft  := FALSE;
    xBefehlSB_Oeffnen := FALSE;
    xBefehlBB_Oeffnen := FALSE;
    xBypassSB         := FALSE;
    xBypassBB         := FALSE;
    rDM_Soll          := 0.0;
    rRpm_Soll         := 0.0;
    iFunktion         := FUNKTION_KEINE;
    iBremseAngewaehlt := BREMSE_KEINE;
    iStoercode        := ERR_KEIN;

    (* Verriegelung nur aufheben, wenn beide Bremsen sicher geschlossen sind *)
    IF xSB_Ist_Zu AND xBB_Ist_Zu THEN
        iBremseOffenLatch := BREMSE_KEINE;
    END_IF

    IF rtModusEin.Q AND xFrg_Gesamt AND xFrg_Stillstand AND xSB_Ist_Zu AND xBB_Ist_Zu THEN
        xTestBremseAktiv := TRUE;
        iSchritt := SCHRITT_BEREIT;
    END_IF

(* ---------------------------------------------------------------- *)
SCHRITT_BEREIT:
    xBefehlSB_Oeffnen := FALSE;
    xBefehlBB_Oeffnen := FALSE;
    xBypassSB         := FALSE;
    xBypassBB         := FALSE;
    xBremstestLaeuft  := FALSE;
    rDM_Soll          := 0.0;
    rRpm_Soll         := 0.0;

    IF xSB_Ist_Zu AND xBB_Ist_Zu THEN
        iBremseOffenLatch := BREMSE_KEINE;
    END_IF

    (* Oeffnen: geoeffnet wird die Bremse, die NICHT geprueft wird.
       Lueftspaltkontrolle: geoeffnet wird die angewaehlte Bremse selbst. *)
    IF rtOeffnen.Q AND xFrg_Oeffnen THEN
        iStoercode      := ERR_KEIN;
        xQuittungGefahr := FALSE;          (* Quittung ist verbraucht *)
        rSchlupfUmdr    := 0.0;
        rMaxRpmImTest   := 0.0;
        rDM_ErreichtImTest := 0.0;
        xBremstestOK    := FALSE;
        xBremstestNOK   := FALSE;

        IF iFunktion = FUNKTION_LUEFTSPALT THEN
            (* zu pruefende Bremse oeffnen, die andere haelt *)
            IF iBremseAngewaehlt = BREMSE_SB THEN
                iBremseOffenLatch := BREMSE_SB;
            ELSE
                iBremseOffenLatch := BREMSE_BB;
            END_IF
        ELSE
            (* Bremstest: die ANDERE Bremse oeffnen, angewaehlte haelt das Moment *)
            IF iBremseAngewaehlt = BREMSE_SB THEN
                iBremseOffenLatch := BREMSE_BB;
            ELSE
                iBremseOffenLatch := BREMSE_SB;
            END_IF
        END_IF
        iSchritt := SCHRITT_OEFFNEN;
    END_IF

    IF rtModusAus.Q AND (iBremseOffenLatch = BREMSE_KEINE) AND xSB_Ist_Zu AND xBB_Ist_Zu THEN
        iSchritt := SCHRITT_GESPERRT;
    END_IF

(* ---------------------------------------------------------------- *)
SCHRITT_OEFFNEN:
    (* Befehl steht an, Rueckmeldung wird ueberwacht.
       Die Verriegelung iBremseOffenLatch ist bereits gesetzt und bleibt
       gesetzt, bis manuell geschlossen und die RM "zu" da ist.          *)
    xBefehlSB_Oeffnen := (iBremseOffenLatch = BREMSE_SB);
    xBefehlBB_Oeffnen := (iBremseOffenLatch = BREMSE_BB);
    rDM_Soll  := 0.0;
    rRpm_Soll := 0.0;

    IF ((iBremseOffenLatch = BREMSE_SB) AND xSB_Ist_Offen AND xBB_Ist_Zu)
    OR ((iBremseOffenLatch = BREMSE_BB) AND xBB_Ist_Offen AND xSB_Ist_Zu) THEN
        iSchritt := SCHRITT_OFFEN;
    ELSIF tonOeffnen.Q THEN
        iStoercode := ERR_RM_OEFFNEN;
        iSchritt   := SCHRITT_STOERUNG;
    END_IF

    (* jederzeitiger Abbruch durch den Bediener *)
    IF rtSchliessen.Q OR rtTestStop.Q THEN
        iSchritt := SCHRITT_SCHLIESSEN;
    END_IF

(* ---------------------------------------------------------------- *)
SCHRITT_OFFEN:
    (* Eine Bremse ist offen: Lueftspalt messen/einstellen oder Bremstest starten.
       Ohne laufenden Test steht der Antrieb momentfrei.                        *)
    xBefehlSB_Oeffnen := (iBremseOffenLatch = BREMSE_SB);
    xBefehlBB_Oeffnen := (iBremseOffenLatch = BREMSE_BB);
    xBremstestLaeuft  := FALSE;
    xBypassSB         := FALSE;
    xBypassBB         := FALSE;
    rDM_Soll          := 0.0;
    rRpm_Soll         := 0.0;

    IF rtTestStart.Q AND xFrg_TestStart THEN
        rSchlupfUmdr  := 0.0;
        rMaxRpmImTest := 0.0;
        xBremstestOK  := FALSE;
        xBremstestNOK := FALSE;
        iSchritt      := SCHRITT_TEST_RAMPE;
    END_IF

    IF rtSchliessen.Q THEN
        iSchritt := SCHRITT_SCHLIESSEN;
    END_IF

(* ---------------------------------------------------------------- *)
SCHRITT_TEST_RAMPE:
    (* Moment rampenfoermig gegen die geschlossene Bremse aufbauen.
       Drehzahlsollwert bleibt im engen Testfenster - haelt die Bremse,
       bleibt der Antrieb in der Momentbegrenzung stehen.              *)
    xBremstestLaeuft  := TRUE;
    xBefehlSB_Oeffnen := (iBremseOffenLatch = BREMSE_SB);
    xBefehlBB_Oeffnen := (iBremseOffenLatch = BREMSE_BB);
    xBypassSB         := (iBremseAngewaehlt = BREMSE_SB);   (* SB ist zu, Antrieb darf Moment geben *)
    xBypassBB         := (iBremseAngewaehlt = BREMSE_BB);

    rDM_Soll  := rDM_Soll + rRampeDMproSek * (ZYKLUS_MS / 1000.0);
    IF rDM_Soll > rDM_Ziel THEN
        rDM_Soll := rDM_Ziel;
    END_IF
    rRpm_Soll := rRpmSollTest * rRichtung;

    (* Schlupfueberwachung *)
    rSchlupfUmdr  := rSchlupfUmdr + ABS(rIstRpm) / 60.0 * (ZYKLUS_MS / 1000.0);
    IF ABS(rIstRpm) > rMaxRpmImTest THEN
        rMaxRpmImTest := ABS(rIstRpm);
    END_IF
    rDM_ErreichtImTest := ABS(rIstDM);

    IF (ABS(rIstRpm) > rRpmSchlupfGrenze) OR (rSchlupfUmdr > rSchlupfGrenzeUmdr) THEN
        xBremstestNOK := TRUE;
        iLetztesTestergebnis := 2;
        iStoercode := ERR_TEST_NOK;
        iSchritt   := SCHRITT_TEST_ABBAU;
    ELSIF rDM_Soll >= rDM_Ziel THEN
        iSchritt := SCHRITT_TEST_HALTEN;
    END_IF

    IF rtTestStop.Q OR rtSchliessen.Q THEN
        iSchritt := SCHRITT_TEST_ABBAU;
    END_IF

(* ---------------------------------------------------------------- *)
SCHRITT_TEST_HALTEN:
    xBremstestLaeuft  := TRUE;
    xBefehlSB_Oeffnen := (iBremseOffenLatch = BREMSE_SB);
    xBefehlBB_Oeffnen := (iBremseOffenLatch = BREMSE_BB);
    xBypassSB         := (iBremseAngewaehlt = BREMSE_SB);
    xBypassBB         := (iBremseAngewaehlt = BREMSE_BB);
    rDM_Soll          := rDM_Ziel;
    rRpm_Soll         := rRpmSollTest * rRichtung;

    rSchlupfUmdr := rSchlupfUmdr + ABS(rIstRpm) / 60.0 * (ZYKLUS_MS / 1000.0);
    IF ABS(rIstRpm) > rMaxRpmImTest THEN
        rMaxRpmImTest := ABS(rIstRpm);
    END_IF
    rDM_ErreichtImTest := ABS(rIstDM);

    IF (ABS(rIstRpm) > rRpmSchlupfGrenze) OR (rSchlupfUmdr > rSchlupfGrenzeUmdr) THEN
        xBremstestNOK := TRUE;
        iLetztesTestergebnis := 2;
        iStoercode := ERR_TEST_NOK;
        iSchritt   := SCHRITT_TEST_ABBAU;
    ELSIF tonHaltezeit.Q THEN
        xBremstestOK := TRUE;
        iLetztesTestergebnis := 1;
        iSchritt := SCHRITT_TEST_ABBAU;
    END_IF

    IF rtTestStop.Q OR rtSchliessen.Q THEN
        iSchritt := SCHRITT_TEST_ABBAU;
    END_IF

(* ---------------------------------------------------------------- *)
SCHRITT_TEST_ABBAU:
    (* Moment definiert abbauen, Bremse bleibt offen -> manuelles Schliessen bleibt Pflicht *)
    xBremstestLaeuft  := TRUE;
    xBefehlSB_Oeffnen := (iBremseOffenLatch = BREMSE_SB);
    xBefehlBB_Oeffnen := (iBremseOffenLatch = BREMSE_BB);
    xBypassSB         := (iBremseAngewaehlt = BREMSE_SB);
    xBypassBB         := (iBremseAngewaehlt = BREMSE_BB);
    rRpm_Soll         := 0.0;

    rDM_Soll := rDM_Soll - rRampeDMproSek * (ZYKLUS_MS / 1000.0);
    IF rDM_Soll <= 0.0 THEN
        rDM_Soll         := 0.0;
        xBremstestLaeuft := FALSE;
        xBypassSB        := FALSE;
        xBypassBB        := FALSE;
        IF xBremstestNOK THEN
            iSchritt := SCHRITT_STOERUNG;     (* Ergebnis n.i.O. muss quittiert werden *)
        ELSE
            iSchritt := SCHRITT_OFFEN;        (* Bremse weiterhin offen, Bediener schliesst *)
        END_IF
    END_IF

(* ---------------------------------------------------------------- *)
SCHRITT_SCHLIESSEN:
    (* Manuelles Schliessen: Befehl weg -> federbetaetigte Bremse faellt zu.
       Erst mit Rueckmeldung "zu" wird die Verriegelung aufgehoben und die
       andere Bremse darf ueberhaupt wieder geoeffnet werden.               *)
    xBefehlSB_Oeffnen := FALSE;
    xBefehlBB_Oeffnen := FALSE;
    xBypassSB         := FALSE;
    xBypassBB         := FALSE;
    xBremstestLaeuft  := FALSE;
    rDM_Soll          := 0.0;
    rRpm_Soll         := 0.0;

    IF xSB_Ist_Zu AND xBB_Ist_Zu THEN
        iBremseOffenLatch := BREMSE_KEINE;     (* Verriegelung aufgehoben *)
        IF iStoercode <> ERR_KEIN THEN
            iSchritt := SCHRITT_STOERUNG;
        ELSE
            iSchritt := SCHRITT_BEREIT;
        END_IF
    ELSIF tonSchliessen.Q THEN
        iStoercode := ERR_RM_SCHLIESSEN;
        iSchritt   := SCHRITT_STOERUNG;
    END_IF

(* ---------------------------------------------------------------- *)
SCHRITT_STOERUNG:
    (* Sicherer Zustand: keine Oeffnungsbefehle, kein Moment.
       Die Verriegelung bleibt bestehen, bis die Bremse quittiert geschlossen ist. *)
    xBefehlSB_Oeffnen := FALSE;
    xBefehlBB_Oeffnen := FALSE;
    xBypassSB         := FALSE;
    xBypassBB         := FALSE;
    xBremstestLaeuft  := FALSE;
    rDM_Soll          := 0.0;
    rRpm_Soll         := 0.0;

    IF rtQuittieren.Q THEN
        IF NOT (xSB_Ist_Zu AND xBB_Ist_Zu) THEN
            iSchritt := SCHRITT_SCHLIESSEN;          (* zuerst sauber schliessen *)
        ELSIF xFrg_Gesamt THEN
            iBremseOffenLatch := BREMSE_KEINE;
            iStoercode        := ERR_KEIN;
            xBremstestNOK     := FALSE;
            iSchritt          := SCHRITT_BEREIT;
        ELSE
            iStoercode       := ERR_KEIN;
            xTestBremseAktiv := FALSE;
            iSchritt         := SCHRITT_GESPERRT;
        END_IF
    END_IF

ELSE
    iSchritt := SCHRITT_GESPERRT;
END_CASE

(* ================================================================================
   F) STATUSBILDUNG
   ================================================================================ *)
xTestBremseOffen         := xTestBremseAktiv
                        AND (xBefehlSB_Oeffnen OR xBefehlBB_Oeffnen OR xSB_Ist_Offen OR xBB_Ist_Offen);
xManuellSchliessenNoetig := (iBremseOffenLatch <> BREMSE_KEINE);
xAntriebFreigabeTest     := xBremstestLaeuft AND xFrg_Gesamt;

(* Doppelte Begrenzung der Sollwerte - unabhaengig von der Schrittkette *)
rDM_Soll    := LIMIT(0.0, rDM_Soll, rDMMaxZulaessig);
rRpm_Grenze := ABS(rRpmSollTest);
rRpm_Soll   := LIMIT(-rRpm_Grenze, rRpm_Soll, rRpm_Grenze);
IF NOT xBremstestLaeuft THEN
    rDM_Soll  := 0.0;
    rRpm_Soll := 0.0;
END_IF

(* ================================================================================
   G) AUSGABEN AN DIE ANLAGE
   ================================================================================ *)

(* --- G1: Bypass-Bits fuer die Bremsen-Freigabekette --- *)
g_IO.Standbremsentest := xBypassSB;
(* g_IO.Betriebsbremsentest := xBypassBB; *)   (*TODO*) (* neue Variable in der GVL anlegen und freischalten *)

(* Bestehende Grundregel beibehalten: ohne Service-Mode kein Bremsmodus *)
IF NOT g_IO.ServiceMode THEN
    g_IO.Standbremsentest := FALSE;
    (* g_IO.Betriebsbremsentest := FALSE; *)   (*TODO*)
END_IF

(* --- G2: Bremsenansteuerung ---
   Nur im Bremsmodus greift dieses PRG auf die Bremsen zu; im Normalbetrieb
   bleibt die bestehende Ansteuerung unveraendert.
   TODO: auf die realen Ausgangsvariablen der Bremsen mappen: *)
IF xTestBremseAktiv THEN
    (* g_IO.SB_Lueften := xBefehlSB_Oeffnen; *)   (*TODO*)
    (* g_IO.BB_Lueften := xBefehlBB_Oeffnen; *)   (*TODO*)
    ;
END_IF

(* --- G3: Antriebssollwerte ---
   Im Bremsmodus werden Moment und Drehzahl ausschliesslich hier vorgegeben.
   PRG in der Task NACH der Windensteuerung aufrufen, damit diese Werte gelten. *)
IF xTestBremseAktiv THEN
    (*TODO*) (* Typ pruefen: falls Solldrehmoment INT ist -> REAL_TO_INT(rDM_Soll) *)
    IO_Hauptinverter.Solldrehmoment  := rDM_Soll;
    IO_Hauptinverter.SollRpmInverter := REAL_TO_INT(LIMIT(-rRpm_Grenze, rRpm_Soll, rRpm_Grenze));
END_IF

(* ================================================================================
   H) DIAGNOSETEXTE FUER DIE VISU
   ================================================================================ *)
CASE iSchritt OF
    SCHRITT_GESPERRT:      sSchrittText := 'Bremsmodus gesperrt';
    SCHRITT_BEREIT:        sSchrittText := 'Bereit - Bremse und Funktion waehlen';
    SCHRITT_OEFFNEN:       sSchrittText := 'Bremse wird geoeffnet';
    SCHRITT_OFFEN:         sSchrittText := 'Bremse OFFEN - Klemmgefahr!';
    SCHRITT_TEST_RAMPE:    sSchrittText := 'Bremstest - Moment wird aufgebaut';
    SCHRITT_TEST_HALTEN:   sSchrittText := 'Bremstest - Pruefmoment wird gehalten';
    SCHRITT_TEST_ABBAU:    sSchrittText := 'Bremstest - Moment wird abgebaut';
    SCHRITT_SCHLIESSEN:    sSchrittText := 'Bremse manuell schliessen';
    SCHRITT_STOERUNG:      sSchrittText := 'Stoerung - quittieren';
ELSE
    sSchrittText := '';
END_CASE

CASE iStoercode OF
    ERR_KEIN:              sStoerText := '';
    ERR_SERVICEMODE:       sStoerText := 'Service-Mode abgefallen';
    ERR_USERLEVEL:         sStoerText := 'Userlevel zu niedrig';
    ERR_NOTAUS:            sStoerText := 'Not-Aus / Pilz nicht ok';
    ERR_BEIDE_OFFEN:       sStoerText := 'Beide Bremsen offen - unzulaessig!';
    ERR_BEWEGUNG:          sStoerText := 'Bewegung bei offener Bremse';
    ERR_MOMENT:            sStoerText := 'Unzulaessiges Moment';
    ERR_RM_OEFFNEN:        sStoerText := 'Rueckmeldung OFFEN fehlt';
    ERR_RM_SCHLIESSEN:     sStoerText := 'Rueckmeldung ZU fehlt';
    ERR_TEST_NOK:          sStoerText := 'Bremstest n.i.O. - Bremse haelt nicht';
    ERR_ZEIT_OFFEN:        sStoerText := 'Max. Offenzeit ueberschritten';
    ERR_BETRIEBSART:       sStoerText := 'Betriebsart sperrt den Bremsmodus';
    ERR_ANTRIEB:           sStoerText := 'Umrichter nicht bereit';
ELSE
    sStoerText := 'Unbekannte Stoerung';
END_CASE
