# TestBremse_Controls — comando manuale freni winda (CODESYS 3.5.18.4)

`POUs/TestBremse_Controls.st` — PROGRAM (PRG) in Structured Text per il modo
**Manual Test Bremse**: in Service Mode l'operatore apre e chiude a mano i due freni
della winda, uno alla volta.

Sigle mantenute perché corrispondono all'I/O reale:
**SB** = Standbremse (freno di stazionamento) · **BB** = Betriebsbremse (freno di servizio).

## Come si comporta

| Punto | Implementazione |
|---|---|
| Stato reale | `g_IO.SBoffen` / `g_IO.BBoffen` **TRUE = freno APERTO** |
| Ingresso nel modo | i comandi interni vengono allineati ai feedback: un freno già aperto resta aperto e va chiuso a mano |
| Un solo freno aperto | si apre solo se l'altro è chiuso per comando **e** per feedback (`SBclosed` / `BBclosed`) |
| Chiusura | sempre ammessa, nessuna condizione davanti |
| Comandi visu | impulsi: il PRG li esegue e li **azzera**, quindi non possono restare attivi insieme |
| Precedenze | `CmdTestOff` prima di `CmdTestOn`, `CmdClose…` prima di `CmdOpen…` |
| Timer | nessuno: apertura e chiusura seguono subito il comando |
| Consenso permanente | `EnableOk` (Service Mode, livello utente, Notaus Pilz, fermo macchina, coppia libera): se cade, i comandi di apertura vanno via |
| Due freni aperti | `FaultBothOpen` ⇒ tutti e due i comandi cadono |

La sicurezza vera (un solo freno aperto, Notaus, fermo macchina, limitazione della coppia)
resta nel **Pilz**. Questo PRG è il livello funzionale e la guida operatore.

## Uscite verso la Pilz

Un solo segnale per freno, il freno chiude a molla quando cade il comando:

```
IOPilzWinde.Out_SBtest           := OutSB_Open;   (* TRUE = apri, FALSE = chiudi *)
IOPilzWinde.Out_BBtest           := OutBB_Open;
IOPilzWinde.Out_ManualTestBremse := ManualTestBremse;
```

Le uscite vengono scritte a ogni ciclo: fuori dal modo i comandi interni sono già a FALSE,
quindi non resta appeso nessun comando di apertura.

## Visualizzazione

I pulsanti scrivono direttamente su `TestBremse_Controls.Cmd…` (tipo "a impulso").
Abilitazione dinamica con i flag `en…`:

| Pulsante | Abilitazione |
|---|---|
| Attiva modo | `enTestOn` |
| Esci dal modo | `enTestOff` |
| Apri SB / BB | `enOpenSB` / `enOpenBB` |
| Chiudi SB / BB | `enCloseSB` / `enCloseBB` |
| Avviso permanente | `ManualCloseRequired` ⇒ "Bremse manuell schliessen!" |
| Diagnosi | `brakeOpenFb`, `FaultBothOpen`, `WarnNoFeedback`, `WarnOpenExtern` |

## Prove consigliate

* Ingresso nel modo con `SBoffen = TRUE` ⇒ `OutSB_Open` resta TRUE, "apri BB" bloccato finché SB non è chiusa a mano.
* SB chiusa, BB aperta ⇒ "apri SB" bloccato; chiudere BB e riaprire.
* `CmdTestOn` e `CmdTestOff` insieme ⇒ vince OFF, tutti e due tornano a FALSE.
* Notaus o chiave Service Mode durante il modo ⇒ comandi di apertura a zero, freni chiusi.

## Documentazione

`doc/Betriebsanleitung_Bremsentest.md` — bozza del capitolo di manuale d'uso, in tedesco perché
destinata all'impianto: procedura passo passo e avvertenze di pericolo. Descrive anche la prova
freni con coppia, che in questa versione del PRG non è implementata.
