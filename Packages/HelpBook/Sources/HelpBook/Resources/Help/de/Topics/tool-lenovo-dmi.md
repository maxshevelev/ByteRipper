@source-sha a45086a7b08f79b23db89a50e4867cbcb92034629c0093b1291f22795d2fc38d
# Lenovo DMI

> Der Speicher, in dem die Firmware Lenovo InsydeH2O die Identität eines Geräts ablegt – Seriennummer, UUID, Maschinentyp und Modell, Windows-Schlüssel –, dekodiert und ausgewertet.

**Werkzeuge ▸ Lenovo DMI** sucht in einem Image von Lenovo InsydeH2O den Identitätsspeicher und zeigt dessen Inhalt.

Bei diesen Geräten findet eine Suche nach der Seriennummer vom Typenschild im Dump nichts: Lenovo legt die [[term:dmi|DMI]]-Felder nicht im Klartext ab, sondern in einem eigenen Speicher, dessen Bytes sämtlich mit einem Schlüssel per XOR verknüpft sind. Dieses Panel macht den Speicher lesbar.

## Wo der Speicher liegt

Der Speicher besteht aus drei aufeinanderfolgenden Bereichen: dem 8 KiB großen Änderungsprotokoll [[term:ldbg|LDBG]] und zwei [[term:lenv|LENV]]-Blöcken zu je 4 KiB. Seine Lage im Image ist von Platine zu Platine verschieden. Das Werkzeug sucht ihn deshalb über die Signatur `LDBG` und erkennt ihn nur an, wenn mindestens einer der beiden Blöcke an der erwarteten Stelle die Signatur `LENV` trägt. In den untersuchten Images führt die [[term:flash-device-map|Insyde Flash Device Map]] dieselben drei Bereiche als Regionen vom Typ Unknown.

Findet das Werkzeug keinen Speicher, sagt das Panel dies. Das Image stammt dann von einer anderen Plattform, oder der Bereich wurde herausgeschnitten.

## Was das Panel zeigt

- **Der Baum** enthält das Änderungsprotokoll und beide Blöcke. Ein aufgeklappter Block listet seine Einträge, das aufgeklappte Protokoll seine Ereignisse.
- **Die Zeile über dem Baum** nennt den Block, den die Firmware liest, seine Generation und die Zahl seiner Einträge.
- **Die Detailliste** unter dem Baum beschreibt die ausgewählte Zeile. Das `?` neben ihrem Namen erklärt den Begriff.
- **Die Hinweise** unter der Detailliste melden einen leeren Speicher, eine nicht stimmende Prüfsumme oder voneinander abweichende Blöcke.

Im Dump wird nur die ausgewählte Zeile als aktive Zone umrahmt. Bei einem Eintrag eines Blocks oder einem Ereignis des Protokolls wird zusätzlich der umgebende Block bzw. das Protokoll als inaktive Zone umrahmt, sodass der Dump sowohl die Bytes zeigt als auch, wozu sie gehören. Solange nichts ausgewählt ist, erscheint kein Rahmen.

Ein Doppelklick auf eine Zeile oder **Im Dump auswählen** in ihrem Kontextmenü wählt ihre Bytes im Dump aus. **Wert kopieren** legt den Wert so, wie das Panel ihn anzeigt, in die Zwischenablage.

## Welchen Block die Firmware liest

Der Speicher liegt doppelt vor, in **LENV-Block 1** und **LENV-Block 2**, damit ein durch Stromausfall unterbrochener Schreibvorgang eine unversehrte Kopie hinterlässt. Jeder Blockkopf trägt eine **Generation**: einen Zähler, der wächst, während die Firmware den Speicher neu schreibt. In allen untersuchten funktionierenden Dumps unterscheiden sich die beiden Generationen um eins, etwa 127 und 126, und der Block mit der höheren Nummer enthält den jüngeren Stand. Das passt zu einer Firmware, die jede neue Kopie über den älteren Block schreibt und ihr die nächste Nummer gibt; der Code, der das tut, wurde hier nicht untersucht.

Die Firmware liest den Block mit der höheren Generation; das Panel nennt ihn den **aktiven** Block. Diese Regel stammt aus der Analyse von `LenovoVariableDxe` durch LenovoDMIDecryptor, und die untersuchten Dumps bestätigen sie: Der Eintrag, den das letzte Ereignis des Protokolls entfernt, fehlt im Block mit der höheren Generation und ist im anderen noch vorhanden. Bei gleicher Generation wertet das Werkzeug wie LenovoDMIDecryptor Block 1 als aktiv.

Generation **0** kommt auf einer funktionierenden Platine nicht vor. Sie zeigt ein Block, dessen Kopf genullt wurde, etwa in einem gelöschten Speicher; einen solchen Block liest die Firmware nicht. Haben beide Blöcke Generation 0, gibt es nichts zu lesen. Ein Block, dessen Bytes sämtlich `FF` sind, wurde gelöscht und seitdem nicht beschrieben; das Panel nennt ihn gelöscht, und die Firmware liest die andere Kopie.

Ob die Firmware auf den anderen Block ausweicht, wenn die Prüfsumme des aktiven nicht stimmt, ist nicht bekannt; das Panel weist an der betreffenden Stelle darauf hin.

Die beiden Blöcke können unterschiedliche Werte enthalten. Nach einem Schreibvorgang ist das normal: Die ältere Kopie behält die vorigen Werte. Ein Wert, der in einen anderen Dump übertragen werden soll, wird daher dem aktiven Block entnommen; die Detailliste jedes Eintrags gibt an, ob der andere Block denselben Wert enthält.

## Dekodierten Block öffnen

**Dekodierten Block öffnen** im Kontextmenü eines Blocks oder eines seiner Einträge öffnet den ganzen Block in einem [[topic:fragments|Fragment-Panel]], mit dekodierten Einträgen: Seriennummer und Maschinentyp stehen in der Hex-Ansicht als Text und lassen sich dort bearbeiten. Der Kopf bleibt so, wie er gespeichert ist; Schlüssel und Prüfsumme stehen an ihren eigenen Adressen.

**In der Quelle aktualisieren** schreibt den Block als einen Widerrufsschritt in den Dump zurück, kodiert mit dem Schlüssel aus seinem Kopf und mit neu berechneter Prüfsumme. Länge und Generation des Blocks bleiben unverändert, und dem Protokoll wird nichts hinzugefügt. Geschrieben wird nur der geöffnete Block; um beide Kopien zu ändern, öffnen und aktualisieren Sie jede einzeln. Die Kopfzeile des Fragments trägt ein Abzeichen **XOR** mit dem Schlüssel, das daran erinnert, dass seine Bytes nicht die der Datei sind.

**Werkzeuge ▸ Lenovo DMI**, auf diesem Fragment geöffnet, zeigt die Struktur des Blocks: Kopf und Einträge, so gelesen wie im Dump. Ein Fragment enthält weder das Änderungsprotokoll noch die zweite Kopie; das Panel sagt daher nicht, welche Kopie die Firmware liest. Die Prüfsumme im Kopf ist die des kodierten Blocks, und das Panel wertet sie als solche als gültig. Nach einer Änderung im Fragment stimmt sie nicht mehr und erscheint rot mit dem Wert, den sie haben müsste; **In der Quelle aktualisieren** schreibt diesen Wert.

Der Befehl steht für einen Block zur Verfügung, der Einträge enthält und dessen Kodierung erkannt wurde; für einen leeren Block und für das Protokoll nicht.

## Die Einträge

Ein Eintrag ist durch einen Namensraum und einen Typ bestimmt. Für den Namensraum SMBIOS sind folgende Typen bekannt: der Windows-Schlüssel, die OA3-Schlüssel-ID, die Bezeichnung der Hauptplatine, Maschinentyp und Modell (MTM), die Seriennummer der Hauptplatine, die System-UUID, die Plattform-ID der Hauptplatine und das Suffix des vorinstallierten Betriebssystems. Diese Einträge benennt das Panel und zeigt ihre Werte als Text, die UUID in der Bytereihenfolge von SMBIOS.

In realen Images kommen weitere Typen vor, deren Bedeutung nicht dokumentiert ist. Das Panel bezeichnet sie als unbekannt, nennt die Typnummer und zeigt den Wert als Text, sofern alle Bytes druckbar sind, andernfalls hexadezimal. Die Merkmale eines Eintrags und zwei seiner Felder, die in allen untersuchten Images null sind, werden unverändert wiedergegeben.

**Von der Firmware gelesen** in der Detailliste eines Eintrags nennt die Treiber dieses Images, die den Eintrag bei der Firmware abfragen. Das Werkzeug findet sie, indem es den Code jedes Treibers im Image nach dem Schlüssel des Eintrags durchsucht, nachdem der Speicher angezeigt ist; in den untersuchten Images dauert das weniger als eine Sekunde. Dort liest zum Beispiel `InstallMsdm` den Windows-Schlüssel und baut daraus die ACPI-Tabelle MSDM, und `L05SmbiosOverride` oder `OemUpdateSMBios` liest die Einträge, aus denen die SMBIOS-Tabellen gefüllt werden – so zeigt sich, wofür ein Eintrag dient, auch wo seine Bedeutung nicht dokumentiert ist. Ein Treiber, der den Schlüssel zur Laufzeit berechnet, statt ihn als Konstante zu nennen, wird nicht gefunden; **Kein Treiber dieses Images greift darauf zu** bedeutet daher, dass kein Treiber den Schlüssel als Konstante nennt. Für einen Block, der für sich in einem Fragment geöffnet ist, entfällt die Zeile: Um ihn herum gibt es keine Firmware.

## Der Eintrag des Windows-Schlüssels

Im Eintrag des Windows-Schlüssels steht vor dem Produktschlüssel ein Kopf von 20 Bytes. Er ist die Lizenzstruktur der ACPI-Tabelle [[term:slic|MSDM]], wie die Spezifikation von Microsoft ([[web:https://learn.microsoft.com/en-us/previous-versions/windows/hardware/design/dn653305(v=vs.85)|Microsoft Software Licensing Tables (SLIC and MSDM)]]) sie festlegt und die Firmware Test Suite sie prüft ([[web:https://lists.ubuntu.com/archives/fwts-devel/2015-July/006546.html|fwts MSDM test]]). Alle Felder sind 32 Bit breit, niederwertiges Byte zuerst:

- **Version** – in allen untersuchten Dumps 1; die Firmware Test Suite prüft sie nicht.
- **Reserviert** – null.
- **Datentyp** – 1, ein Produktschlüssel.
- **Daten reserviert** – null.
- **Datenlänge** – 29 (`1D000000`), die Länge des Schlüssels.
- **Daten** – der Schlüssel selbst, `XXXXX-XXXXX-XXXXX-XXXXX-XXXXX`.

Die ersten 16 Bytes lauten daher stets `01000000 00000000 01000000 00000000`, und das Panel behandelt sie als Signatur. Als Wert erscheint nur der Schlüssel; der Kopf wird in der Detailliste unter **Schlüsselkopf** beschrieben. Der Schlüssel wird nur dann vom Kopf getrennt, wenn die Signatur vorhanden ist und die angegebene Länge der Zahl der folgenden Bytes entspricht; andernfalls wird der Eintrag als Bytes gezeigt und als fehlerhaft markiert, und **Schlüsselkopf** nennt die Bedingung, die nicht erfüllt ist.

## Das Änderungsprotokoll

Das Protokoll hält fest, was die Firmware wann in den Speicher geschrieben hat: Datum und Uhrzeit aus der Echtzeituhr, den Vorgang, den Eintrag und die Zahl der Bytes. Werte enthält es nicht. Bei einem Ereignis, das vor dem Stellen der Uhr geschrieben wurde, stehen statt des Datums dessen Bytes. Ein **Schreiben** von null Bytes erscheint als **Entfernen**: In den untersuchten Images fehlt der Eintrag danach im neueren Block.

## Was bekannt ist und was nicht

Das Format hat das Projekt [[web:https://github.com/Shmurkio/LenovoDMIDecryptor|LenovoDMIDecryptor]] aus dem Modul `LenovoVariableDxe` rekonstruiert; das Projekt [[web:https://github.com/Shmurkio/LenovoVar|LenovoVar]] desselben Autors, das den Speicher über das Protokoll der Firmware selbst liest und schreibt, bestätigt die Eintragstypen und die Bytereihenfolge der UUID. Das Werkzeug wurde an realen Dumps überprüft. Wo die Beschreibung des Projekts und die Dumps voneinander abweichen, folgt das Werkzeug den Dumps: Ein Protokollereignis ist 32 Bytes lang, obwohl die Feldoffsets der Beschreibung zusammen 24 ergeben, und das Jahr eines Ereignisses ist als BCD-Jahrhundert und BCD-Jahr gespeichert, nicht als 2000 plus ein Byte.

Nicht bestätigt ist, wie die Firmware auf die Schreibschutzbits eines Blocks und eines Eintrags reagiert, und was die unbekannten Typen und Felder enthalten. Das Änderungsprotokoll ist nicht immer mit dem Schlüssel der Blöcke kodiert: In einem der untersuchten Dumps sind die Blöcke mit `A0` und das Protokoll mit `88` kodiert. Der freie Platz des Protokolls besteht aus kodierten Nullen; das wiederholte Byte nach dem letzten Ereignis ist daher sein Schlüssel, und das Werkzeug entnimmt ihn dort.

! Das Werkzeug selbst ändert nichts am Speicher: Bearbeitet wird in einem Fragment, das mit „Dekodierten Block öffnen“ geöffnet und mit „In der Quelle aktualisieren“ zurückgeschrieben wird; ob die Platine danach mit den neuen Werten startet, ist nicht bestätigt. Sind beide Blöcke leer, wurde der Speicher gelöscht oder nie beschrieben: Seriennummer und UUID der Platine sind in diesem Image nicht enthalten. Sie lassen sich dann nur einem früheren Dump derselben Platine, sofern einer aufbewahrt wurde, oder dem Typenschild entnehmen.

Siehe auch: [[topic:recipe-board-data|Platinenspezifische Daten]], [[term:dmi|DMI]].
