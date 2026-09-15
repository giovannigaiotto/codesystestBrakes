# Bremsmodus — Lüftspaltkontrolle und Bremsentest

Entwurf für die Betriebsanleitung (Kapitel Service / Instandhaltung).
Vor Freigabe durch den Sicherheitsverantwortlichen prüfen und ergänzen.

---

## 1. Zweck

Im Bremsmodus kann eine der beiden Windenbremsen gezielt geöffnet werden, um

* den **Lüftspalt** zu kontrollieren und einzustellen,
* einen **Bremstest** durchzuführen (Haltemoment der jeweils geschlossenen Bremse).

Die jeweils andere Bremse hält die Winde. **Es ist immer nur eine Bremse geöffnet.**

## 2. GEFAHRENHINWEISE

> ⚠️ **WARNUNG — Klemmgefahr**
> Beim Schliessen der Bremse besteht Quetsch- und Klemmgefahr an Bremszange,
> Bremsbelag und Bremsscheibe. Nie mit Händen oder Werkzeug zwischen Belag und
> Scheibe greifen, solange die Bremse geöffnet ist und der Not-Aus nicht betätigt ist.
> Die Bremse schliesst federbetätigt und schlagartig, sobald die Ansteuerung wegfällt
> (Not-Aus, Spannungsausfall, Störung, Ablauf der Überwachungszeit).

> ⚠️ **WARNUNG — Absturz der Last / Durchgehen der Winde**
> Bei geöffneter Bremse hält nur noch die zweite Bremse. Fällt diese aus, bewegt sich
> die Winde unkontrolliert.
> **Winde vor Beginn so weit wie möglich entlasten:**
> * ohne Nutzlast fahren,
> * Fahrzeug/Wagen im Puffer der Talstation oder an einer flachen Stelle abstellen,
> * ist das nicht möglich, muss das Zugseil mechanisch abgefangen werden.

> ⚠️ **WARNUNG — Bremstest**
> Beim Bremstest wird bewusst Moment gegen die geschlossene Bremse aufgebaut.
> Gefahrenbereich der Winde, des Seils und der Umlenkungen räumen. Kein Aufenthalt
> im Seilbereich. Nur eine Person bedient, eine zweite Person beobachtet.

## 3. Voraussetzungen

1. Winde entlastet (siehe oben), Anlage stillgesetzt.
2. Schlüsselschalter **Service-Mode** eingeschaltet.
3. Anmeldung am Display mit **Benutzerlevel 2** oder höher.
4. Not-Aus-Kreis in Ordnung (Pilz-Meldung „NA ok"). Der Not-Aus bleibt während des
   gesamten Vorgangs aktiv und wirksam.
5. Antrieb bereit, keine anstehende Störung, Anlage im Stillstand.
6. Gefahrenhinweis am Display bestätigen (Bestätigung verfällt nach 60 s).

Fällt eine dieser Bedingungen während des Vorgangs weg, werden die Bremsen-
ansteuerung und das Drehmoment sofort weggenommen; die Bremsen schliessen.

## 4. Ablauf Lüftspaltkontrolle

1. Am Display Seite **Bremsen / Service** öffnen (nur mit Service-Mode und Benutzerlevel).
2. Bremsmodus anwählen — es müssen beide Bremsen geschlossen sein.
3. Zu prüfende Bremse wählen: **Standbremse (SB)** oder **Betriebsbremse (BB)**.
4. Funktion **Lüftspaltkontrolle** wählen.
5. Gefahrenhinweis bestätigen, dann **Bremse öffnen**. Die Rückmeldung „offen"
   wird innerhalb von 3 s erwartet, sonst Störung.
6. Lüftspalt messen und gemäss Herstellerangabe einstellen.
   Es wird kein Drehmoment aufgebaut; der Antrieb bleibt momentfrei.
7. **Bremse manuell schliessen** (Taste am Display). Erst wenn die Rückmeldung
   „geschlossen" ansteht, gibt die Steuerung die zweite Bremse frei.
8. Für die zweite Bremse Schritte 3–7 wiederholen.

> **Hinweis:** Solange eine Bremse geöffnet war und noch nicht quittiert geschlossen ist,
> ist das Öffnen der anderen Bremse gesperrt. Die Meldung „Bremse manuell schliessen"
> bleibt am Display stehen.

## 5. Ablauf Bremstest

1. Schritte 1–3 wie oben; als Bremse die **zu prüfende** Bremse wählen.
2. Funktion **Bremstest** wählen und Prüfrichtung (Zug-/Gegenrichtung) einstellen.
3. Gefahrenhinweis bestätigen, dann **Bremse öffnen**: geöffnet wird die *andere*
   Bremse, die zu prüfende Bremse bleibt geschlossen und hält.
4. **Bremstest starten**. Das Drehmoment wird rampenförmig bis zum parametrierten
   Prüfmoment aufgebaut und für die eingestellte Haltezeit gehalten.
5. Bewertung durch die Steuerung:
   * **i.O.**: Drehzahl und aufintegrierte Verdrehung bleiben innerhalb der Grenzwerte.
   * **n.i.O.**: Grenzwert überschritten ⇒ Moment wird sofort abgebaut, Bremsen
     schliessen, Störung „Bremstest n.i.O." Die Bremse ist instand zu setzen;
     die Anlage darf nicht in Betrieb genommen werden.
6. Nach Testende **Bremse manuell schliessen** (Pflicht, siehe oben).
7. Ergebnis, Datum, Prüfmoment und Prüfer im Prüfprotokoll eintragen.

## 6. Abbruch und Störungen

| Meldung | Ursache | Massnahme |
|---|---|---|
| Not-Aus / Pilz nicht ok | Not-Aus betätigt oder Sicherheitskreis offen | Ursache beheben, entriegeln, quittieren |
| Service-Mode abgefallen | Schlüsselschalter zurückgedreht | Service-Mode einschalten |
| Benutzerlevel zu niedrig | Abmeldung / Timeout | Neu anmelden (Level ≥ 2) |
| Beide Bremsen offen — unzulässig | Rückmeldung oder Ansteuerung defekt | Anlage stillsetzen, Instandhaltung |
| Bewegung bei offener Bremse | haltende Bremse rutscht | Gefahrenbereich verlassen, Winde sichern, Instandhaltung |
| Unzulässiges Moment | Antrieb gibt Moment ab | Antrieb prüfen |
| Rückmeldung OFFEN/ZU fehlt | Endschalter, Ventil, Verdrahtung | Instandhaltung |
| Bremstest n.i.O. | Bremse hält Prüfmoment nicht | Bremse instand setzen, Test wiederholen |
| Max. Offenzeit überschritten | Bremse zu lange offen | Arbeit beenden, Bremse schliessen |

Quittieren erfolgt am Display. Ist noch eine Bremse offen, führt die Quittierung
zuerst in den Schritt „Bremse manuell schliessen"; anschliessend erneut quittieren.

## 7. Nach Abschluss der Arbeiten

1. Beide Bremsen geschlossen, Rückmeldungen geprüft.
2. Bremsmodus verlassen, Schlüsselschalter Service-Mode ausschalten und Schlüssel abziehen.
3. Abgefangenes Zugseil lösen, Werkzeug und Messmittel entfernen.
4. Funktionsprobe im Normalbetrieb ohne Nutzlast.
5. Eintrag im Wartungsprotokoll.
