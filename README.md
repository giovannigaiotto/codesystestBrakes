# TestBremse_Controls — comando manuale dei freni (CODESYS 3.5.18.4)

`POUs/TestBremse_Controls.st` — PRG in Structured Text: **apre e chiude a mano** i due
freni della winda in Service Mode, uno per volta, dentro il modo `ManualTestBremse`
che viene mandato al PILZ. Nessuna prova freni, nessuna coppia imposta.

SB = Standbremse = freno di stazionamento · BB = Betriebsbremse = freno di servizio.

## Nel modo i freni li comanda questo PRG

Finché `ManualTestBremse` è TRUE, le uscite dei freni le scrive questo PRG **tutti i
cicli, anche a FALSE**. È l'unica cosa che permette di **chiudere** un freno che si
trova già aperto quando si entra nella pagina. Fuori dal modo le uscite restano alla
gestione winda, che non viene toccata.

Perché funzioni servono due cose:
1. richiamare il PRG nel task **dopo** la gestione winda;
2. collegare le uscite reali nelle righe `(*TODO*)` della sezione 8 — **finché sono
   commentate nessun pulsante muove niente in impianto**.

```
IF ManualTestBremse THEN
    g_IO.SB_Lueften := OutSB_Open;      (* nome reale da mettere *)
    g_IO.BB_Lueften := OutBB_Open;      (* nome reale da mettere *)
END_IF
```

## Variabili che ENTRANO nel PRG

| Variabile | Sorgente | Significato |
|---|---|---|
| `in_ServiceMode` | `g_IO.ServiceMode` | chiave di Service Mode |
| `in_UserLevel` | `CurrentUserLevel` | livello utente, serve ≥ `MinUserLevel` (= 2) |
| `in_NAok` | `IOPilzWinde.K_NAok_VZ` | Notaus / Pilz ok |
| `in_Rpm` | `IO_Hauptinverter.ActualSpeed` | giri/min, serve ≤ `RpmStandstill` (= 2.0) |
| `in_Torque` | `IO_Hauptinverter.ActualDM` | coppia reale, serve ≤ `TorqueFreeLimit` (= 50.0) |
| `in_SBoffen` / `in_BBoffen` | `g_IO.SBoffen` / `g_IO.BBoffen` | feedback "freno aperto" |
| `CmdTestOn` / `CmdTestOff` | visu, pulsanti a impulso | entra / esci dal modo |
| `CmdOpenSB` / `CmdCloseSB` | visu, pulsanti a impulso | apri SB / chiudi SB |
| `CmdOpenBB` / `CmdCloseBB` | visu, pulsanti a impulso | apri BB / chiudi BB |

## Variabili che ESCONO dal PRG

| Variabile | Destinazione | Significato |
|---|---|---|
| `ManualTestBremse` | **PILZ** *(TODO: mappare)* | status del modo manuale |
| `OutSB_Open` / `OutBB_Open` | uscite freni *(TODO: mappare)* | comando di apertura |
| `EnableOk` | visu | consenso generale, condizione **permanente** |
| `enTestOn` / `enTestOff` | visu | abilitazione dei pulsanti di modo |
| `enOpenSB` / `enOpenBB` | visu | abilitazione dei pulsanti di apertura |
| `enCloseSB` / `enCloseBB` | visu | abilitazione dei pulsanti di chiusura |
| `brakeOpenFb` | visu | **stato dai feedback**: 0 nessuno / 1 SB / 2 BB / 3 entrambi |
| `BrakeOpenOk` | visu | freno aperto da qui, feedback presente dopo 5 s |
| `BothClosedOk` | visu | **interblocco libero**: tutti e due chiusi da 5 s |
| `ManualCloseRequired` | visu | un freno risulta aperto: va richiuso |
| `FaultBothOpen` | visu | anomalia: risultano aperti tutti e due |
| `WarnNoFeedback` | visu | dopo 5 s manca il feedback "aperto" |
| `WarnOpenExtern` | visu | freno aperto **mentre non comando niente** |

Interne: `cmdSB_Open` / `cmdBB_Open` (cosa comando io, mai tutte e due insieme).

**`cmd…` e `brakeOpenFb` sono due cose diverse**: il primo è quello che comando io e
diventa `OutSB_Open` / `OutBB_Open`; il secondo è solo quello che vedo in impianto.
`WarnOpenExtern` accende la differenza: uscite non ancora collegate (righe TODO), freno
tenuto aperto da altri, o feedback `offen` non coerente.

## Sequenza, partendo dal caso tipico SB aperta / BB chiusa

```
EnableOk = ServiceMode AND UserLevel>=2 AND NAok AND fermo AND scarico   (permanente)

CmdTestOn  -> ManualTestBremse = TRUE, comandi a zero -> la SB viene comandata chiusa
feedback SB caduto + 5 s -> BothClosedOk -> enOpenSB / enOpenBB
CmdOpenBB  -> OutBB_Open = TRUE          (BothClosedOk cade: la SB non si apre)
5 s        -> BrakeOpenOk                (senza feedback: WarnNoFeedback)
CmdCloseBB -> OutBB_Open = FALSE, il freno chiude a molla
feedback BB caduto + 5 s -> BothClosedOk -> si può aprire l'altro
CmdTestOff -> ManualTestBremse = FALSE, uscite di nuovo alla gestione winda
```

* **OFF esce sempre**, senza condizioni: azzera i comandi e restituisce le uscite.
  È la via d'uscita sicura e non va mai bloccata.
* **La chiusura non ha consensi**: `CmdCloseSB` / `CmdCloseBB` tolgono il comando e basta.
* **L'apertura** vuole modo attivo, `EnableOk` e `BothClosedOk`: è lì che vive la regola
  "un solo freno aperto" e la richiusura manuale obbligatoria.
* Se cade la chiave di **Service Mode** il modo cade e le uscite tornano alla gestione
  winda. Se cade il resto di `EnableOk` (Notaus, livello, movimento, coppia) i comandi
  di apertura vanno via ma il modo resta: i freni sono comandati chiusi.

## Requisiti coperti

| Richiesta | Dove |
|---|---|
| Service Mode | `in_ServiceMode` in `EnableOk`, e il modo cade con la chiave |
| Livello utente 2 | `in_UserLevel >= MinUserLevel` |
| Notaus sempre attivo | `in_NAok` in `EnableOk` (permanente) |
| Winda ferma / azionamento scarico | `in_Rpm` e `in_Torque` in `EnableOk` (permanente) |
| Un solo freno aperto | `BothClosedOk` in `enOpenSB` / `enOpenBB`, e i comandi si escludono |
| Richiusura manuale obbligatoria | `BothClosedOk` arriva solo 5 s dopo la caduta dei feedback |
| Status verso il PILZ | `ManualTestBremse` |
| Descrizione del rischio | `doc/Betriebsanleitung_Bremsentest.md` |

## Volutamente NON presente

Prova freni (coppia rampata, slittamento, esito i.O./n.i.O.), simulazione dei feedback,
codici di anomalia, testi di stato, scrittura dei setpoint dell'inverter. Il PRG **non
scrive** su `IO_Hauptinverter`: nessuna coppia viene imposta. Il controllo vero è nel PILZ.
Il Bremstest si aggiunge come secondo blocco sopra questa base
(la versione completa resta nella storia git, commit `f4e84e3`).

## Da completare

1. Uscite reali di apertura SB/BB nella sezione 8 (le due righe `(*TODO*)` dentro
   `IF ManualTestBremse THEN`) e variabile di scambio verso il PILZ.
2. Richiamo nel task **dopo** la gestione winda.
3. Se esistono i feedback "chiuso" (`SBzu` / `BBzu`), usarli al posto della negazione di
   "aperto": con un sensore rotto i due segnali non sono coerenti.
4. Tarare `RpmStandstill` e `TorqueFreeLimit` sui valori reali dell'inverter.

## Visu

Blocco già presente sulla pagina, da mantenere:
`((IOPilzWinde.K_NAok_VZ) AND (g_IO.ServiceMode) AND (CurrentUserLevel>=2)) = FALSE`.
In più sui pulsanti: `NOT enTestOn`, `NOT enTestOff`, `NOT enOpenSB`, `NOT enCloseSB`,
`NOT enOpenBB`, `NOT enCloseBB`. Avvisi: `ManualCloseRequired`, `FaultBothOpen`,
`WarnNoFeedback`, `WarnOpenExtern`.

## Prove in impianto

* SB aperta, BB chiusa ⇒ premi ON: la SB deve chiudersi. Se non si muove niente,
  le uscite della sezione 8 non sono collegate oppure il PRG non è chiamato dopo la
  gestione winda.
* Dopo la caduta di `g_IO.SBoffen` contare 5 s: solo allora `enOpenSB` / `enOpenBB`.
* Apri BB, poi premi ON/OFF: con OFF il modo cade sempre e la BB si chiude.
* Togli Service Mode / Notaus, o muovi la winda con un freno aperto ⇒ comandi via subito.
* `brakeOpenFb <> 0` con la winda ferma e i freni visibilmente chiusi ⇒ il feedback
  `g_IO.SBoffen` / `g_IO.BBoffen` non è coerente: controllare cablaggio e polarità
  prima di andare avanti, tutto l'interblocco si appoggia su quei due bit.

## Documentazione

`doc/Betriebsanleitung_Bremsentest.md` — bozza del capitolo di manuale (in tedesco):
procedura, pericolo di schiacciamento, scarico della winda, controllo del traferro.
Descrive la funzione completa, quindi anche il Bremstest non ancora implementato.
