# TestBremse_Controls — apertura forzata dei freni (CODESYS 3.5.18.4)

`POUs/TestBremse_Controls.st` — PRG in Structured Text, **versione minima da banco**:
apre **un solo** freno della winda in Service Mode e obbliga a richiuderlo
manualmente prima di poter aprire l'altro. Niente altro.

SB = Standbremse = freno di stazionamento · BB = Betriebsbremse = freno di servizio.

## Variabili che ENTRANO nel PRG

| Variabile | Sorgente | Significato |
|---|---|---|
| `in_ServiceMode` | `g_IO.ServiceMode` | chiave di Service Mode |
| `in_UserLevel` | `CurrentUserLevel` *(TODO)* | livello utente, serve ≥ `MinUserLevel` (= 2) |
| `in_NAok` | `IOPilzWinde.K_NAok_VZ` | Notaus / Pilz ok |
| `in_Rpm` | `IO_Hauptinverter.ActualSpeed` *(TODO)* | giri/min, serve ≤ `RpmStandstill` (= 2.0) |
| `in_SBoffen` / `in_BBoffen` | `g_IO.SBoffen` / `g_IO.BBoffen` | feedback "freno aperto" |
| `CmdOpenSB` / `CmdOpenBB` / `CmdClose` | visu, pulsanti a impulso | apri SB / apri BB / chiudi |
| `simOn`, `simSBoffen`, `simBBoffen` | solo banco | sovrascrivono i due feedback |

## Variabili che ESCONO dal PRG

| Variabile | Destinazione | Significato |
|---|---|---|
| `OutSB_Open` / `OutBB_Open` | uscite freni *(TODO: mappare)* | comando di apertura |
| `EnableOk` | visu | consenso generale, condizione **permanente** |
| `enOpenSB` / `enOpenBB` | visu | abilitazione dei pulsanti di apertura |
| `enClose` | visu | abilitazione del pulsante di chiusura |
| `ManualCloseRequired` | visu | interblocco attivo: il freno va ancora richiuso |

Interne: `brakeCmd` (freno comandato aperto 0/1/2) e `brakeLatch` (interblocco 0/1/2).

## Logica in quattro righe

```
EnableOk := ServiceMode AND (UserLevel >= 2) AND NAok AND (ABS(Rpm) <= RpmStandstill);
enOpenSB := EnableOk AND (brakeLatch = 0) AND entrambi i feedback "aperto" caduti;
apertura  -> brakeCmd := 1|2 e brakeLatch := 1|2
chiusura  -> brakeCmd := 0; brakeLatch cade SOLO quando il feedback "aperto" e' caduto
```

Se `EnableOk` cade (Service Mode, livello, Notaus, movimento) oppure risultano aperti
tutti e due i freni, il comando viene tolto subito e il freno chiude a molla.
L'interblocco **resta**: l'altro freno non si apre finché il primo non è chiuso davvero.

## Requisiti coperti

| Richiesta | Dove |
|---|---|
| Service Mode | `in_ServiceMode` in `EnableOk` (permanente) |
| Livello utente 2 | `in_UserLevel >= MinUserLevel` |
| Notaus sempre attivo | `in_NAok` in `EnableOk` (permanente) |
| Un solo freno aperto | `brakeLatch` + `enOpenSB` / `enOpenBB` |
| Richiusura manuale obbligatoria | `brakeLatch` cade solo con comando tolto e feedback "aperto" caduto |
| Descrizione del rischio | `doc/Betriebsanleitung_Bremsentest.md` |

## Volutamente NON presente

Prova freni (coppia rampata, slittamento, esito i.O./n.i.O.), controllo traferro come
funzione separata, codici di anomalia, testi di stato, timer di sorveglianza, conferma
del pericolo, scrittura dei setpoint dell'inverter. Il PRG **non tocca**
`IO_Hauptinverter`: nessuna coppia viene imposta. Il controllo vero resta nel PILZ.
Il Bremstest si aggiunge come secondo blocco quando questa parte è provata al banco
(la versione completa resta nella storia git, commit `f4e84e3`).

## Integrazione

1. Richiamare il PRG nel task **dopo** la normale gestione winda.
2. Togliere il commento alle due righe `g_IO.SB_Lueften` / `g_IO.BB_Lueften` con i nomi reali.
3. Verificare nome e tipo di giri reali e livello utente (righe `(*TODO*)`).
4. Se nel progetto esistono i feedback "chiuso" (`SBzu` / `BBzu`), usare quelli al posto
   della negazione di "aperto": con un sensore rotto i due segnali non sono coerenti.

## Visu

Blocco già presente sulla pagina, da mantenere:
`((IOPilzWinde.K_NAok_VZ) AND (g_IO.ServiceMode) AND (CurrentUserLevel>=2)) = FALSE`.
In più sui pulsanti: "apri SB" ⇒ `NOT enOpenSB`, "apri BB" ⇒ `NOT enOpenBB`,
"chiudi" ⇒ `NOT enClose`. Avviso fisso se `ManualCloseRequired`.

## Prove al banco

* `simOn := TRUE`, apri SB ⇒ `OutSB_Open` TRUE, `enOpenBB` FALSE.
* Con SB ancora aperta premi "chiudi" ⇒ comando via, ma `enOpenBB` resta FALSE
  finché `simSBoffen` non torna FALSE.
* Togli Service Mode / Notaus / muovi la winda con un freno aperto ⇒ comando via subito.

## Documentazione

`doc/Betriebsanleitung_Bremsentest.md` — bozza del capitolo di manuale (in tedesco):
procedura, pericolo di schiacciamento, scarico della winda, controllo del traferro.
Descrive la funzione completa, quindi anche il Bremstest non ancora implementato.
