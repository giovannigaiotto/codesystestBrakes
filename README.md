# TestBremse_Controls — comando bremse in sicurezza (CODESYS 3.5.18.4)

`POUs/TestBremse_Controls.st` — PROGRAM (PRG) in Structured Text per:

1. **Lüftspaltkontrolle**: apertura di **una sola** freno, mentre l'altro tiene la winda.
2. **Bremstest**: coppia rampata contro il freno chiuso, con sorveglianza dello slittamento.

## Punti chiave implementati (richiesta del capo)

| Richiesta | Implementazione |
|---|---|
| Service Mode | `xFrg_ServiceMode := g_IO.ServiceMode` — condizione **permanente**, non solo di ingresso |
| Userlevel 2 | `xFrg_Userlevel := (iUserlevel >= MIN_USERLEVEL)`, `MIN_USERLEVEL = 2` |
| Bremstest | passi `SCHRITT_TEST_RAMPE / _HALTEN / _ABBAU` con rampa, tempo di mantenimento e criterio di slittamento (giri/min + giri integrati) |
| Solo un freno aperto | latch `iBremseOffenLatch` (0/SB/BB): finché ≠ 0 nessuna apertura è possibile |
| Chiusura manuale obbligatoria | il latch si azzera **solo** in `SCHRITT_SCHLIESSEN` con retroazione "chiuso" presente |
| Notaus attivo | `IOPilzWinde.K_NAok_VZ` è condizione permanente; caduta ⇒ abort immediato |
| Nessuna coppia/velocità pericolosa | blocchi D1…D5: fermo macchina, coppia libera, movimento a freno aperto, coppia massima, tempo massimo di apertura |

Il programma **non** scavalca nessuna funzione di sicurezza: l'interblocco sicuro
(un solo freno aperto, Not-Aus, controllo fermo macchina, limitazione sicura della
coppia) resta da realizzare nel **Pilz**. Questo PRG è il livello funzionale + guida operatore.

## Integrazione (5 passi)

1. **Chiamata task**: richiamare `TestBremse_Controls` **dopo** la normale gestione winda,
   così i setpoint forzati a 0 sono gli ultimi scritti.
2. **Rimuovere il vecchio blocco** `IF g_io.Standbremsentest THEN IO_Hauptinverter.Solldrehmoment := …`.
   La scrittura dei setpoint ora è solo qui.
3. **Nuova variabile GVL**: `Betriebsbremsentest : BOOL;` e catena di consenso estesa:
   ```
   g_IO.AlleBremsenoffen := (g_IO.SBoffen OR g_IO.Standbremsentest)
                        AND (g_IO.BBoffen OR g_IO.Betriebsbremsentest);
   ```
   Poi togliere il commento alle due righe `(*TODO*)` di `g_IO.Betriebsbremsentest` nella sezione G.
4. **Righe `(*TODO*)`**: sono le uniche interfacce da adattare ai nomi/tipi reali
   (istwert giri e coppia, "Bereit" inverter, retroazione `SBzu`, uscite di lüftung dei freni,
   sorgente dell'userlevel, tipo di `Solldrehmoment`).
5. **Parametri**: `rDMTest_SB`, `rDMTest_BB` e `rDMMaxZulaessig` partono da **0.0** ⇒ il
   Bremstest è bloccato finché non vengono parametrizzati (scelta voluta).
   Adattare anche `ZYKLUS_MS` al tempo di ciclo del task.

## Visualizzazione

I pulsanti scrivono direttamente su `TestBremse_Controls.xBedien…` (tipo "tasto", fronte di salita).
Mantenere le sperrungen esistenti e aggiungere l'enable dinamico:

| Elemento | Sperre / Enable |
|---|---|
| Ingresso pagina | `NOT (g_IO.ServiceMode AND PLC_PRG.userlevel3)` |
| Tutti i pulsanti | `((IOPilzWinde.K_NAok_VZ) AND (g_IO.ServiceMode) AND (CurrentUserLevel>=2)) = FALSE` |
| "Bremse öffnen" | in più: `NOT TestBremse_Controls.xFrg_Oeffnen` |
| "Bremstest starten" | in più: `NOT TestBremse_Controls.xFrg_TestStart` |
| Testo di stato | `TestBremse_Controls.sSchrittText` / `.sStoerText` |
| Avviso permanente | `TestBremse_Controls.xManuellSchliessenNoetig` ⇒ "Bremse manuell schliessen!" |

## Test consigliati prima della messa in servizio

* Simulazione: aprire SB ⇒ verificare che "apri BB" resti bloccato finché SB non è chiusa manualmente.
* Notaus durante freno aperto ⇒ comando di apertura cade, latch resta, stato `SCHRITT_STOERUNG`.
* Chiave Service Mode indietro durante il test ⇒ coppia a 0 e freni chiusi.
* Rimozione retroazione "offen"/"zu" ⇒ `ERR_RM_OEFFNEN` / `ERR_RM_SCHLIESSEN`.
* Bremstest con freno volutamente male regolato ⇒ risultato `n.i.O.` senza corsa incontrollata.
