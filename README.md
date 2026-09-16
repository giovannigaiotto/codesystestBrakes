# TestBremse_Controls — apertura forzata dei freni (CODESYS 3.5.18.4)

`POUs/TestBremse_Controls.st` — PRG in Structured Text: apre **un solo** freno della
winda in Service Mode, dentro il modo `ManualTestBremse` che viene mandato al PILZ.
Nessuna prova freni, nessuna coppia imposta.

SB = Standbremse = freno di stazionamento · BB = Betriebsbremse = freno di servizio.

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
| `CmdOpenSB` / `CmdOpenBB` / `CmdClose` | visu, pulsanti a impulso | apri SB / apri BB / chiudi |

## Variabili che ESCONO dal PRG

| Variabile | Destinazione | Significato |
|---|---|---|
| `ManualTestBremse` | **PILZ** *(TODO: mappare)* | status del modo di apertura manuale |
| `OutSB_Open` / `OutBB_Open` | uscite freni *(TODO: mappare)* | comando di apertura |
| `EnableOk` | visu | consenso generale, condizione **permanente** |
| `enTestOn` / `enTestOff` | visu | abilitazione dei pulsanti di modo |
| `enOpenSB` / `enOpenBB` / `enClose` | visu | abilitazione dei pulsanti di apertura e chiusura |
| `brakeOpen` | visu | quale freno è aperto: 0 nessuno / 1 SB / 2 BB (**interblocco**) |
| `BrakeOpenOk` | visu | freno aperto con feedback stabile da 5 s |
| `BothClosedOk` | visu | tutti e due chiusi con feedback stabile da 5 s |
| `ManualCloseRequired` | visu | il freno aperto va ancora richiuso a mano |
| `FaultBothOpen` | visu | anomalia: risultano aperti tutti e due |
| `WarnNoFeedback` | visu | dopo 5 s manca il feedback "aperto" |

Interna: `brakeCmd` (quale freno sto comandando aperto, 0/1/2).
Parametri: `RpmStandstill`, `TorqueFreeLimit`, `MinUserLevel`, `tSettle` (= T#5S).

## Sequenza

```
EnableOk = ServiceMode AND UserLevel>=2 AND NAok AND fermo AND scarico   (permanente)

  CmdTestOn -> ManualTestBremse = TRUE            (status al PILZ)
  entrambi chiusi da 5 s (BothClosedOk) -> enOpenSB / enOpenBB
  CmdOpenBB -> OutBB_Open = TRUE, brakeOpen = 2   (interblocco: SB non si apre piu')
  5 s -> BrakeOpenOk                              (senza feedback: WarnNoFeedback)
  CmdClose  -> OutBB_Open = FALSE, il freno chiude a molla
  feedback "aperto" caduto + 5 s -> BothClosedOk, brakeOpen = 0
  CmdTestOff -> ManualTestBremse = FALSE          (solo con brakeOpen = 0)
```

`brakeOpen` segue il **feedback reale**: se all'ingresso nel modo un freno è già aperto,
si entra lo stesso ma è quello che va richiuso per primo, e nessun altro freno si apre.

Se `EnableOk` cade (Service Mode, livello, Notaus, movimento, coppia), se il modo viene
tolto o se risultano aperti tutti e due i freni, il comando cade subito. L'interblocco
`brakeOpen` **resta**, e finché non è a zero non si esce nemmeno dal modo.

## Requisiti coperti

| Richiesta | Dove |
|---|---|
| Service Mode | `in_ServiceMode` in `EnableOk` (permanente) |
| Livello utente 2 | `in_UserLevel >= MinUserLevel` |
| Notaus sempre attivo | `in_NAok` in `EnableOk` (permanente) |
| Winda ferma / azionamento scarico | `in_Rpm` e `in_Torque` in `EnableOk` (permanente) |
| Un solo freno aperto | `brakeOpen` + `enOpenSB` / `enOpenBB` |
| Richiusura manuale obbligatoria | `brakeOpen` cade solo con `BothClosedOk` (5 s) |
| Status verso il PILZ | `ManualTestBremse` |
| Descrizione del rischio | `doc/Betriebsanleitung_Bremsentest.md` |

## Volutamente NON presente

Prova freni (coppia rampata, slittamento, esito i.O./n.i.O.), simulazione dei feedback,
codici di anomalia, testi di stato, scrittura dei setpoint dell'inverter. Il PRG **non
scrive** su `IO_Hauptinverter`: nessuna coppia viene imposta. Il controllo vero è nel PILZ.
Il Bremstest si aggiunge come secondo blocco sopra questa base
(la versione completa resta nella storia git, commit `f4e84e3`).

## Integrazione

1. Richiamare il PRG nel task **dopo** la normale gestione winda.
2. Tre righe `(*TODO*)` in fondo: uscite reali di apertura SB/BB e variabile di scambio
   verso il PILZ per `ManualTestBremse`.
3. Se nel progetto esistono i feedback "chiuso" (`SBzu` / `BBzu`), usarli al posto della
   negazione di "aperto": con un sensore rotto i due segnali non sono coerenti.
4. Tarare `RpmStandstill` e `TorqueFreeLimit` sui valori reali dell'inverter.

## Visu

Blocco già presente sulla pagina, da mantenere:
`((IOPilzWinde.K_NAok_VZ) AND (g_IO.ServiceMode) AND (CurrentUserLevel>=2)) = FALSE`.
In più sui pulsanti: `NOT enTestOn`, `NOT enTestOff`, `NOT enOpenSB`, `NOT enOpenBB`,
`NOT enClose`. Avviso fisso se `ManualCloseRequired`, `FaultBothOpen`, `WarnNoFeedback`.

## Prove in impianto

* Entrambi chiusi ⇒ attiva il modo, apri BB, dopo 5 s `BrakeOpenOk`; `enOpenSB` resta FALSE.
* Premi "chiudi": `enOpenSB` torna TRUE solo 5 s dopo la caduta di `g_IO.BBoffen`.
* Togli Service Mode / Notaus, o muovi la winda con un freno aperto ⇒ comando via subito,
  `brakeOpen` resta e il modo non si lascia.
* Entra nel modo con un freno già aperto ⇒ nessuna apertura ammessa, `ManualCloseRequired`.

## Documentazione

`doc/Betriebsanleitung_Bremsentest.md` — bozza del capitolo di manuale (in tedesco):
procedura, pericolo di schiacciamento, scarico della winda, controllo del traferro.
Descrive la funzione completa, quindi anche il Bremstest non ancora implementato.
