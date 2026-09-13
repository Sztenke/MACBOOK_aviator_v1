# AVIATOR Sync Mac

MacOS SwiftUI/CoreBluetooth app az AVIATOR F-Series Mark 1 / AVW79215G360 órához.

Funkciók:
- közeli BLE eszközök listázása (akkor is, ha a macOS Bluetooth Beállításokban nem jelennek meg)
- csatlakozás az AVIATOR órához
- az eredeti Mark 1 protokoll 6006/8001 UUID-jain keresztül a Mac aktuális dátumának és idejének elküldése

A normál macOS Bluetooth listában az óra hiánya nem probléma; ez az app közvetlen CoreBluetooth BLE scan-t végez.
