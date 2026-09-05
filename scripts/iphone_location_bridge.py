#!/usr/bin/env python3
"""Bridge the macOS menu app to usbmux and iOS developer location services."""

from __future__ import annotations

import argparse
import asyncio
import json
import math
import sys
import uuid
from typing import Any

COMPANION_BUNDLE_ID = "com.example.LocationSimulator"
CURRENT_LOCATION_FILE = "/Documents/current-location.json"


def emit(event: str, *, stream: Any = sys.stdout, **payload: Any) -> None:
    """Emit one flushed JSON line for the Swift process bridge."""
    print(json.dumps({"event": event, **payload}, ensure_ascii=False), file=stream, flush=True)


async def list_devices() -> None:
    """Return paired USB iPhones using the system usbmux daemon."""
    from pymobiledevice3 import usbmux
    from pymobiledevice3.lockdown import create_using_usbmux

    devices: list[dict[str, str]] = []
    errors: list[str] = []
    for mux_device in await usbmux.list_devices():
        if not mux_device.is_usb:
            continue
        try:
            async with await create_using_usbmux(
                serial=mux_device.serial,
                autopair=False,
                connection_type="USB",
            ) as lockdown:
                info = lockdown.short_info
                if info.get("DeviceClass") != "iPhone":
                    continue
                devices.append(
                    {
                        "udid": str(info.get("UniqueDeviceID") or mux_device.serial),
                        "name": str(info.get("DeviceName") or "iPhone"),
                        "productType": str(info.get("ProductType") or "iPhone"),
                        "osVersion": str(info.get("ProductVersion") or "未知"),
                        "transport": mux_device.connection_type,
                    }
                )
        except Exception as error:
            errors.append(str(error))

    if not devices and errors:
        raise RuntimeError(errors[0])
    emit("devices", devices=devices)


async def set_location(udid: str, latitude: float, longitude: float) -> None:
    """Hold one DVT location override until the Mac closes the stdin session."""
    from pymobiledevice3.remote.native_tunnel import NativeRemotedTunnel
    from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
    from pymobiledevice3.services.dvt.instruments.location_simulation import LocationSimulation

    # Apple's native remoted tunnel keeps this path independent of Xcode and avoids a root daemon.
    async with NativeRemotedTunnel(serial=udid) as remote_service:
        async with DvtProvider(remote_service) as dvt, LocationSimulation(dvt) as simulation:
            await simulation.set(latitude, longitude)
            emit("active", latitude=latitude, longitude=longitude)
            await asyncio.to_thread(sys.stdin.readline)
            await simulation.clear()
            emit("cleared")


async def clear_location(udid: str) -> None:
    """Clear a compatible DVT override without requiring its original process."""
    from pymobiledevice3.remote.native_tunnel import NativeRemotedTunnel
    from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
    from pymobiledevice3.services.dvt.instruments.location_simulation import LocationSimulation

    async with NativeRemotedTunnel(serial=udid) as remote_service:
        async with DvtProvider(remote_service) as dvt, LocationSimulation(dvt) as simulation:
            await simulation.clear()
            emit("cleared")


def matching_location_payload(raw_data: bytes, request_id: str) -> dict[str, Any] | None:
    """Accept only the requested fresh coordinate and validate all numeric bounds."""
    payload = json.loads(raw_data)
    if payload.get("requestId") != request_id:
        return None
    if payload.get("error"):
        raise RuntimeError(str(payload["error"]))

    latitude = float(payload["latitude"])
    longitude = float(payload["longitude"])
    horizontal_accuracy = float(payload["horizontalAccuracy"])
    if not math.isfinite(latitude) or not -90 <= latitude <= 90:
        raise RuntimeError("iPhone 返回了无效纬度。")
    if not math.isfinite(longitude) or not -180 <= longitude <= 180:
        raise RuntimeError("iPhone 返回了无效经度。")
    if not math.isfinite(horizontal_accuracy) or horizontal_accuracy < 0:
        raise RuntimeError("iPhone 返回了无效定位精度。")
    return {
        "latitude": latitude,
        "longitude": longitude,
        "horizontalAccuracy": horizontal_accuracy,
    }


async def current_location(udid: str) -> None:
    """Launch the companion and read its request-scoped Core Location payload over USB."""
    from pymobiledevice3.exceptions import AfcFileNotFoundError
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.remote.native_tunnel import NativeRemotedTunnel
    from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
    from pymobiledevice3.services.dvt.instruments.process_control import ProcessControl
    from pymobiledevice3.services.house_arrest import HouseArrestService

    request_id = str(uuid.uuid4())
    async with NativeRemotedTunnel(serial=udid) as remote_service:
        async with DvtProvider(remote_service) as dvt, ProcessControl(dvt) as process_control:
            await process_control.launch(
                bundle_id=COMPANION_BUNDLE_ID,
                arguments=["--location-request", request_id],
                kill_existing=True,
            )

    async with await create_using_usbmux(
        serial=udid,
        autopair=False,
        connection_type="USB",
    ) as lockdown:
        async with await HouseArrestService.create(
            lockdown=lockdown,
            bundle_id=COMPANION_BUNDLE_ID,
            documents_only=False,
        ) as documents:
            deadline = asyncio.get_running_loop().time() + 30
            while asyncio.get_running_loop().time() < deadline:
                try:
                    raw_data = await documents.get_file_contents(CURRENT_LOCATION_FILE)
                except AfcFileNotFoundError:
                    await asyncio.sleep(0.5)
                    continue

                payload = matching_location_payload(raw_data, request_id)
                if payload is not None:
                    emit("current-location", **payload)
                    # Keep the process alive until Swift has retained the payload from stdout.
                    await asyncio.to_thread(sys.stdin.readline)
                    return
                await asyncio.sleep(0.5)

    raise RuntimeError("30 秒内未收到定位，请在 iPhone 上允许 LocationSimulator 使用定位后重试。")


def build_parser() -> argparse.ArgumentParser:
    """Define the stable command contract consumed by the Swift services."""
    parser = argparse.ArgumentParser(description="Control an iPhone location session over USB.")
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("devices")

    set_parser = subparsers.add_parser("set")
    set_parser.add_argument("--udid", required=True)
    set_parser.add_argument("--latitude", required=True, type=float)
    set_parser.add_argument("--longitude", required=True, type=float)

    for command in ("clear", "current"):
        command_parser = subparsers.add_parser(command)
        command_parser.add_argument("--udid", required=True)
    return parser


async def run(arguments: argparse.Namespace) -> None:
    """Dispatch exactly one bridge operation for this process."""
    if arguments.command == "devices":
        await list_devices()
    elif arguments.command == "set":
        await set_location(arguments.udid, arguments.latitude, arguments.longitude)
    elif arguments.command == "clear":
        await clear_location(arguments.udid)
    else:
        await current_location(arguments.udid)


def main() -> int:
    """Translate device-service exceptions into one structured stderr event."""
    arguments = build_parser().parse_args()
    try:
        asyncio.run(run(arguments))
        return 0
    except Exception as error:  # The Swift panel turns the exact device-service failure into guidance.
        emit("error", stream=sys.stderr, message=str(error))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
