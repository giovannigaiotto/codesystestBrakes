# TestBremse_Controls — comando freni in sicurezza (CODESYS 3.5.18.4)

`POUs/TestBremse_Controls.st` — PROGRAM (PRG) in Structured Text per:

1. **Controllo del traferro (Lüftspalt)**: apertura di **un solo** freno, mentre l'altro tiene la winda.
2. **Prova freni (Bremstest)**: coppia rampata contro il freno chiuso, con sorveglianza dello slittamento.

Convenzione adottata: **identificatori interni in inglese**, commenti e descrizioni in italiano.
Restano in tedesco solo i nomi già esistenti nel progetto (`g_IO.Standbremsentest`, `SBoffen`,
`BBzu`, `IOPilzWinde.K_NAok_VZ`, …) e i testi di stato mostrati all'operatore in impianto,
che hanno la traduzione italiana come commento a fianco.

Sigle dei freni, mantenute perché corrispondono all'I/O reale:
**SB** = Standbremse = freno di stazionamento · **BB** = Betriebsbremse = freno di servizio.

## Punti chiave implementati (richiesta della direzione tecnica)

| Richiesta | Implementazione |
|---|---|
| Service Mode | `xEn_ServiceMode := g_IO.ServiceMode` — condizione **permanente**, non solo di ingresso |
| Livello utente 2 | `xEn_UserLevel := (iUserLevel >= MIN_USERLEVEL)`, con `MIN_USERLEVEL = 2` |
| Prova freni | passi `STEP_TEST_RAMP / _HOLD / _RAMPDOWN`, con rampa, tempo di mantenimento e criterio di slittamento (giri/min + giri integrati) |
| Un solo freno aperto | interblocco `iBrakeOpenLatch` (0 / SB / BB): finché è diverso da zero nessuna apertura è possibile |
| Chiusura manuale obbligatoria | l'interblocco si sblocca **solo** in `STEP_CLOSING` e solo con il feedback "chiuso" presente |
| Notaus sempre attivo | `IOPilzWinde.K_NAok_VZ` è condizione permanente: se cade, interruzione immediata |
| Nessuna coppia o velocità pericolosa | sorveglianze D1…D5: fermo macchina, coppia libera, movimento a freno aperto, coppia massima, tempo massimo di apertura |

Il programma **non** scavalca nessuna funzione di sicurezza: l'interblocco sicuro
(un solo freno aperto, Notaus, sorveglianza di fermo macchina, limitazione sicura della
coppia) resta da realizzare nel **Pilz**. Questo PRG è il livello funzionale e la guida operatore.

## Integrazione in 5 passi

1. **Richiamo nel task**: chiamare `TestBremse_Controls` **dopo** la normale gestione winda,
   così i setpoint forzati a zero sono gli ultimi scritti.
2. **Rimuovere il vecchio blocco** `IF g_io.Standbremsentest THEN IO_Hauptinverter.Solldrehmoment := …`:
   la scrittura dei setpoint ora avviene solo qui.
3. **Nuova variabile in GVL**: `Betriebsbremsentest : BOOL;` e catena di consenso estesa:
   ```
   g_IO.AlleBremsenoffen := (g_IO.SBoffen OR g_IO.Standbremsentest)
                        AND (g_IO.BBoffen OR g_IO.Betriebsbremsentest);
   ```
   Poi togliere il commento alle due righe `(*TODO*)` di `g_IO.Betriebsbremsentest` nella sezione G.
4. **Righe `(*TODO*)`**: sono le uniche interfacce da adattare ai nomi e ai tipi reali
   (valore reale giri e coppia, segnale di pronto dell'inverter, feedback `SBzu`,
   uscite di apertura dei freni, sorgente del livello utente, tipo di `Solldrehmoment`).
5. **Parametri**: `rTorqueTestSB`, `rTorqueTestBB` e `rTorqueMax` partono da **0.0**, quindi la
   prova freni resta bloccata finché non vengono tarati (scelta voluta).
   Allineare anche `CYCLE_MS` al tempo di ciclo del task: serve per la rampa e per
   l'integrazione dello slittamento.

## Visualizzazione

I pulsanti scrivono direttamente su `TestBremse_Controls.xCmd…` (tipo "a impulso", fronte di salita).
Mantenere i blocchi già presenti e aggiungere l'abilitazione dinamica:

| Elemento | Blocco / abilitazione |
|---|---|
| Ingresso pagina | `NOT (g_IO.ServiceMode AND PLC_PRG.userlevel3)` |
| Tutti i pulsanti | `((IOPilzWinde.K_NAok_VZ) AND (g_IO.ServiceMode) AND (CurrentUserLevel>=2)) = FALSE` |
| "Apri freno" | in più: `NOT TestBremse_Controls.xEn_Open` |
| "Avvia prova freni" | in più: `NOT TestBremse_Controls.xEn_TestStart` |
| Testo di stato | `TestBremse_Controls.sStepText` / `.sFaultText` |
| Avviso permanente | `TestBremse_Controls.xManualCloseRequired` ⇒ "Bremse manuell schliessen!" |

## Prove consigliate prima della messa in servizio

* In simulazione: aprire SB e verificare che "apri BB" resti bloccato finché SB non è chiusa manualmente.
* Notaus con un freno aperto ⇒ il comando di apertura cade, l'interblocco resta, stato `STEP_FAULT`.
* Chiave di Service Mode riportata indietro durante la prova ⇒ coppia a zero e freni chiusi.
* Feedback "aperto" / "chiuso" tolto ⇒ `ERR_FB_OPEN` / `ERR_FB_CLOSED`.
* Prova freni con un freno volutamente mal regolato ⇒ esito `n.i.O.` senza corsa incontrollata.

## Documentazione

`doc/Betriebsanleitung_Bremsentest.md` — bozza del capitolo di manuale d'uso, in tedesco perché
destinata all'impianto: procedura passo passo, avvertenze di pericolo (schiacciamento,
scarico della winda, recupero del tiro sulla fune) e tabella delle anomalie.
