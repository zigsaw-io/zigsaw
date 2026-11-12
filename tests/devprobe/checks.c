// The device checks of tests/devprobe.zig. In C, for Windows' own headers:
// Media Foundation, WASAPI and the rest are COM interfaces whose tables are
// better taken from them than declared by hand.
//
// Each check opens a device as a desktop program would, and says how far it
// got. Nothing a device gives is kept: a camera frame and the microphone's
// samples are counted and dropped, Bluetooth devices and printers are counted
// and not named, and the location is never read (only whether a report would
// be given).

#define COBJMACROS
#define _WIN32_WINNT 0x0A00
#include <initguid.h>
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <locationapi.h>
#include <bluetoothapis.h>
#include <d3d11.h>
#include <winscard.h>
#include <cfgmgr32.h>
#include <winspool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// What a check returns when it isn't an HRESULT: see devprobe.zig's Outcome.
#define DEVPROBE_NONE 1
#define DEVPROBE_UNKNOWN 2
#define DEVPROBE_EMPTY 3
#define DEVPROBE_SILENT 4

// Device interface classes, as devices register them.
DEFINE_GUID(devprobe_hid, 0x4d1e55b2, 0xf16f, 0x11cf, 0x88, 0xcb, 0x00, 0x11, 0x11, 0x00, 0x00, 0x30);
DEFINE_GUID(devprobe_usb, 0xa5dcbf10, 0x6530, 0x11d2, 0x90, 0x1f, 0x00, 0xc0, 0x4f, 0xb9, 0x51, 0xed);
DEFINE_GUID(devprobe_comport, 0x86e0d1e0, 0x8089, 0x11d0, 0x9c, 0xe4, 0x08, 0x00, 0x3e, 0x30, 0x1f, 0x73);
// KSCATEGORY_VIDEO_CAMERA: what a program that goes to the camera's driver
// itself opens, as DirectShow's do, past Media Foundation's camera service.
DEFINE_GUID(devprobe_camera, 0xe5323777, 0xf976, 0x4f5b, 0x9b, 0x55, 0xb9, 0x46, 0x99, 0xc4, 0x6e, 0x44);

static int failed_at(char *detail, int size, const char *step, HRESULT hr) {
    snprintf(detail, size, "at %s", step);
    return (int)hr;
}

// One frame from the first camera, through Media Foundation.
static int camera(char *detail, int size) {
    IMFAttributes *attrs = NULL;
    IMFActivate **devices = NULL;
    UINT32 count = 0;
    IMFMediaSource *source = NULL;
    IMFSourceReader *reader = NULL;
    const char *step = "MFStartup";
    int result = 0;
    HRESULT hr = MFStartup(MF_VERSION, MFSTARTUP_NOSOCKET);
    if (FAILED(hr)) return failed_at(detail, size, step, hr);

    step = "MFCreateAttributes";
    hr = MFCreateAttributes(&attrs, 1);
    if (FAILED(hr)) goto done;
    step = "SetGUID";
    hr = IMFAttributes_SetGUID(attrs, &MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE, &MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID);
    if (FAILED(hr)) goto done;
    step = "MFEnumDeviceSources";
    hr = MFEnumDeviceSources(attrs, &devices, &count);
    if (FAILED(hr)) goto done;
    if (count == 0) {
        result = DEVPROBE_NONE;
        goto done;
    }
    step = "ActivateObject";
    hr = IMFActivate_ActivateObject(devices[0], &IID_IMFMediaSource, (void **)&source);
    if (FAILED(hr)) goto done;
    step = "MFCreateSourceReaderFromMediaSource";
    hr = MFCreateSourceReaderFromMediaSource(source, NULL, &reader);
    if (FAILED(hr)) goto done;
    step = "ReadSample";
    result = DEVPROBE_EMPTY;
    for (int i = 0; i < 60; i++) {
        DWORD stream = 0, flags = 0, length = 0;
        LONGLONG time = 0;
        IMFSample *sample = NULL;
        hr = IMFSourceReader_ReadSample(reader, (DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, &stream, &flags, &time, &sample);
        if (FAILED(hr)) break;
        if (sample) {
            IMFSample_GetTotalLength(sample, &length);
            IMFSample_Release(sample);
            snprintf(detail, size, "a frame of %lu bytes, of %u camera%s", (unsigned long)length, count, count == 1 ? "" : "s");
            result = 0;
            break;
        }
        if (flags & (MF_SOURCE_READERF_ERROR | MF_SOURCE_READERF_ENDOFSTREAM)) break;
    }

done:
    if (reader) IMFSourceReader_Release(reader);
    if (source) {
        IMFMediaSource_Shutdown(source);
        IMFMediaSource_Release(source);
    }
    if (devices) {
        for (UINT32 i = 0; i < count; i++) IMFActivate_Release(devices[i]);
        CoTaskMemFree(devices);
    }
    if (attrs) IMFAttributes_Release(attrs);
    MFShutdown();
    if (FAILED(hr)) return failed_at(detail, size, step, hr);
    if (result == DEVPROBE_EMPTY) snprintf(detail, size, "the camera opened and gave no frame");
    return result;
}

// The default microphone, read for half a second, or the default speakers,
// started and stopped with nothing played. WASAPI, shared mode.
static int audio(EDataFlow flow, char *detail, int size) {
    IMMDeviceEnumerator *devices = NULL;
    IMMDevice *device = NULL;
    IAudioClient *client = NULL;
    IAudioCaptureClient *capture = NULL;
    WAVEFORMATEX *format = NULL;
    int result = 0;
    const char *step = "CoCreateInstance(MMDeviceEnumerator)";
    HRESULT hr = CoCreateInstance(&CLSID_MMDeviceEnumerator, NULL, CLSCTX_ALL, &IID_IMMDeviceEnumerator, (void **)&devices);
    if (FAILED(hr)) goto done;
    step = "GetDefaultAudioEndpoint";
    hr = IMMDeviceEnumerator_GetDefaultAudioEndpoint(devices, flow, eConsole, &device);
    if (hr == HRESULT_FROM_WIN32(ERROR_NOT_FOUND)) {
        hr = S_OK;
        result = DEVPROBE_NONE;
        goto done;
    }
    if (FAILED(hr)) goto done;
    step = "Activate(IAudioClient)";
    hr = IMMDevice_Activate(device, &IID_IAudioClient, CLSCTX_ALL, NULL, (void **)&client);
    if (FAILED(hr)) goto done;
    step = "GetMixFormat";
    hr = IAudioClient_GetMixFormat(client, &format);
    if (FAILED(hr)) goto done;
    step = "Initialize";
    hr = IAudioClient_Initialize(client, AUDCLNT_SHAREMODE_SHARED, 0, 10000000, 0, format, NULL);
    if (FAILED(hr)) goto done;
    if (flow == eRender) {
        step = "Start";
        hr = IAudioClient_Start(client);
        if (SUCCEEDED(hr)) {
            IAudioClient_Stop(client);
            snprintf(detail, size, "a stream started, nothing played");
        }
        goto done;
    }
    step = "GetService(IAudioCaptureClient)";
    hr = IAudioClient_GetService(client, &IID_IAudioCaptureClient, (void **)&capture);
    if (FAILED(hr)) goto done;
    step = "Start";
    hr = IAudioClient_Start(client);
    if (FAILED(hr)) goto done;
    UINT32 total = 0;
    int sound = 0;
    for (int i = 0; i < 40 && SUCCEEDED(hr) && total < format->nSamplesPerSec / 2; i++) {
        Sleep(50);
        UINT32 packet = 0;
        step = "GetNextPacketSize";
        hr = IAudioCaptureClient_GetNextPacketSize(capture, &packet);
        while (SUCCEEDED(hr) && packet > 0) {
            BYTE *data = NULL;
            UINT32 frames = 0;
            DWORD flags = 0;
            step = "GetBuffer";
            hr = IAudioCaptureClient_GetBuffer(capture, &data, &frames, &flags, NULL, NULL);
            if (FAILED(hr)) break;
            if (!(flags & AUDCLNT_BUFFERFLAGS_SILENT) && data) {
                size_t bytes = (size_t)frames * format->nBlockAlign;
                for (size_t j = 0; j < bytes && !sound; j++) sound = data[j] != 0;
            }
            total += frames;
            IAudioCaptureClient_ReleaseBuffer(capture, frames);
            step = "GetNextPacketSize";
            hr = IAudioCaptureClient_GetNextPacketSize(capture, &packet);
        }
    }
    IAudioClient_Stop(client);
    if (SUCCEEDED(hr)) {
        if (total == 0) {
            result = DEVPROBE_EMPTY;
            snprintf(detail, size, "the microphone opened and gave no samples in 2 s");
        } else if (!sound) {
            result = DEVPROBE_SILENT;
            snprintf(detail, size, "%u samples, every one of them zero", total);
        } else {
            snprintf(detail, size, "%u samples with sound in them", total);
        }
    }

done:
    if (format) CoTaskMemFree(format);
    if (capture) IAudioCaptureClient_Release(capture);
    if (client) IAudioClient_Release(client);
    if (device) IMMDevice_Release(device);
    if (devices) IMMDeviceEnumerator_Release(devices);
    if (FAILED(hr)) return failed_at(detail, size, step, hr);
    return result;
}

// Whether Windows would give a position: the status of its report, which
// isn't read.
static int location(char *detail, int size) {
    ILocation *loc = NULL;
    HRESULT hr = CoCreateInstance(&CLSID_Location, NULL, CLSCTX_INPROC_SERVER, &IID_ILocation, (void **)&loc);
    if (FAILED(hr)) return failed_at(detail, size, "CoCreateInstance(Location)", hr);
    enum LOCATION_REPORT_STATUS status = REPORT_NOT_SUPPORTED;
    hr = ILocation_GetReportStatus(loc, &IID_ILatLongReport, &status);
    ILocation_Release(loc);
    if (FAILED(hr)) return failed_at(detail, size, "GetReportStatus", hr);
    switch (status) {
    case REPORT_RUNNING:
        snprintf(detail, size, "a report is there, unread");
        return 0;
    case REPORT_INITIALIZING:
        snprintf(detail, size, "a report is on its way, unread");
        return 0;
    case REPORT_ACCESS_DENIED:
        snprintf(detail, size, "the report's status");
        return (int)E_ACCESSDENIED;
    case REPORT_NOT_SUPPORTED:
        snprintf(detail, size, "no location provider");
        return DEVPROBE_NONE;
    default:
        snprintf(detail, size, "the report's status is an error");
        return (int)E_FAIL;
    }
}

// The first Bluetooth radio, and how many devices it remembers. No inquiry:
// nothing goes on the air.
static int bluetooth(char *detail, int size) {
    BLUETOOTH_FIND_RADIO_PARAMS params = {sizeof params};
    HANDLE radio = NULL;
    HBLUETOOTH_RADIO_FIND find = BluetoothFindFirstRadio(&params, &radio);
    if (!find) {
        DWORD e = GetLastError();
        if (e == ERROR_NO_MORE_ITEMS) return DEVPROBE_NONE;
        return failed_at(detail, size, "BluetoothFindFirstRadio", HRESULT_FROM_WIN32(e));
    }
    BluetoothFindRadioClose(find);
    BLUETOOTH_RADIO_INFO info = {sizeof info};
    DWORD e = BluetoothGetRadioInfo(radio, &info);
    if (e != ERROR_SUCCESS) {
        CloseHandle(radio);
        return failed_at(detail, size, "BluetoothGetRadioInfo", HRESULT_FROM_WIN32(e));
    }
    BLUETOOTH_DEVICE_SEARCH_PARAMS search = {sizeof search};
    search.fReturnAuthenticated = TRUE;
    search.fReturnRemembered = TRUE;
    search.fReturnConnected = TRUE;
    search.hRadio = radio;
    BLUETOOTH_DEVICE_INFO device = {sizeof device};
    int n = 0;
    HBLUETOOTH_DEVICE_FIND devices = BluetoothFindFirstDevice(&search, &device);
    if (devices) {
        do n++;
        while (BluetoothFindNextDevice(devices, &device));
        BluetoothFindDeviceClose(devices);
    }
    CloseHandle(radio);
    snprintf(detail, size, "the radio opened, %d remembered device%s listed", n, n == 1 ? "" : "s");
    return 0;
}

// Every present interface of a class, opened for reading and writing as a
// program that talks to the device would, and closed. Nothing is sent.
static int interfaces(const GUID *class_guid, char *detail, int size) {
    GUID guid = *class_guid;
    ULONG length = 0;
    CONFIGRET cr = CM_Get_Device_Interface_List_SizeW(&length, &guid, NULL, CM_GET_DEVICE_INTERFACE_LIST_PRESENT);
    if (cr != CR_SUCCESS) {
        snprintf(detail, size, "listing them: CONFIGRET %lu", (unsigned long)cr);
        return (int)E_FAIL;
    }
    if (length <= 1) return DEVPROBE_NONE;
    WCHAR *list = calloc(length, sizeof(WCHAR));
    if (!list) return (int)E_OUTOFMEMORY;
    cr = CM_Get_Device_Interface_ListW(&guid, NULL, list, length, CM_GET_DEVICE_INTERFACE_LIST_PRESENT);
    if (cr != CR_SUCCESS) {
        free(list);
        snprintf(detail, size, "listing them: CONFIGRET %lu", (unsigned long)cr);
        return (int)E_FAIL;
    }
    int total = 0, opened = 0, denied = 0, other = 0;
    DWORD first_other = 0;
    for (WCHAR *p = list; *p; p += wcslen(p) + 1) {
        total++;
        HANDLE h = CreateFileW(p, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
        if (h != INVALID_HANDLE_VALUE) {
            opened++;
            CloseHandle(h);
        } else {
            DWORD e = GetLastError();
            if (e == ERROR_ACCESS_DENIED) {
                denied++;
            } else {
                other++;
                if (!first_other) first_other = e;
            }
        }
    }
    free(list);
    if (total == 0) return DEVPROBE_NONE;
    if (other)
        snprintf(detail, size, "%d of %d opened, %d denied, %d failed (first with error %lu)", opened, total, denied, other, (unsigned long)first_other);
    else
        snprintf(detail, size, "%d of %d opened, %d denied", opened, total, denied);
    if (opened) return 0;
    if (denied) return (int)E_ACCESSDENIED;
    return (int)HRESULT_FROM_WIN32(first_other);
}

// A Direct3D 11 device on the real adapter.
static int gpu(char *detail, int size) {
    ID3D11Device *device = NULL;
    D3D_FEATURE_LEVEL level = 0;
    HRESULT hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0, D3D11_SDK_VERSION, &device, &level, NULL);
    if (FAILED(hr)) return failed_at(detail, size, "D3D11CreateDevice", hr);
    ID3D11Device_Release(device);
    snprintf(detail, size, "a Direct3D 11 device, feature level 0x%x", (unsigned)level);
    return 0;
}

// The printers Windows lists, and the first one opened. Nothing is printed.
static int printer(char *detail, int size) {
    DWORD needed = 0, count = 0;
    const DWORD which = PRINTER_ENUM_LOCAL | PRINTER_ENUM_CONNECTIONS;
    if (!EnumPrintersW(which, NULL, 4, NULL, 0, &needed, &count)) {
        DWORD e = GetLastError();
        if (e != ERROR_INSUFFICIENT_BUFFER) return failed_at(detail, size, "EnumPrinters", HRESULT_FROM_WIN32(e));
    }
    if (needed == 0) return DEVPROBE_NONE;
    BYTE *buffer = malloc(needed);
    if (!buffer) return (int)E_OUTOFMEMORY;
    if (!EnumPrintersW(which, NULL, 4, buffer, needed, &needed, &count)) {
        DWORD e = GetLastError();
        free(buffer);
        return failed_at(detail, size, "EnumPrinters", HRESULT_FROM_WIN32(e));
    }
    if (count == 0) {
        free(buffer);
        return DEVPROBE_NONE;
    }
    HANDLE h = NULL;
    if (!OpenPrinterW(((PRINTER_INFO_4W *)buffer)[0].pPrinterName, &h, NULL)) {
        DWORD e = GetLastError();
        free(buffer);
        snprintf(detail, size, "%lu listed, at OpenPrinter", (unsigned long)count);
        return (int)HRESULT_FROM_WIN32(e);
    }
    ClosePrinter(h);
    free(buffer);
    snprintf(detail, size, "%lu listed, the first opened", (unsigned long)count);
    return 0;
}

// The smart card service, and whether it has a reader.
static int smartcard(char *detail, int size) {
    SCARDCONTEXT context = 0;
    LONG rc = SCardEstablishContext(SCARD_SCOPE_USER, NULL, NULL, &context);
    if (rc == (LONG)SCARD_E_NO_SERVICE || rc == (LONG)SCARD_E_SERVICE_STOPPED) {
        snprintf(detail, size, "the Smart Card service isn't running");
        return DEVPROBE_NONE;
    }
    if (rc != SCARD_S_SUCCESS) return failed_at(detail, size, "SCardEstablishContext", (HRESULT)rc);
    DWORD chars = 0;
    rc = SCardListReadersW(context, NULL, NULL, &chars);
    SCardReleaseContext(context);
    if (rc == (LONG)SCARD_E_NO_READERS_AVAILABLE) {
        snprintf(detail, size, "the service answered, with no reader");
        return DEVPROBE_NONE;
    }
    if (rc != SCARD_S_SUCCESS) return failed_at(detail, size, "SCardListReaders", (HRESULT)rc);
    snprintf(detail, size, "the service answered, with a reader");
    return 0;
}

// Runs the check `name`: 0 if the device answered, a DEVPROBE_ code, or the
// HRESULT of what failed. `detail` gets a few words about it, or none.
int devprobe_check(const char *name, char *detail, int size) {
    detail[0] = 0;
    HRESULT com = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    int result;
    if (!strcmp(name, "camera")) result = camera(detail, size);
    else if (!strcmp(name, "camera-device")) result = interfaces(&devprobe_camera, detail, size);
    else if (!strcmp(name, "microphone")) result = audio(eCapture, detail, size);
    else if (!strcmp(name, "speakers")) result = audio(eRender, detail, size);
    else if (!strcmp(name, "location")) result = location(detail, size);
    else if (!strcmp(name, "bluetooth")) result = bluetooth(detail, size);
    else if (!strcmp(name, "hid")) result = interfaces(&devprobe_hid, detail, size);
    else if (!strcmp(name, "usb")) result = interfaces(&devprobe_usb, detail, size);
    else if (!strcmp(name, "serial")) result = interfaces(&devprobe_comport, detail, size);
    else if (!strcmp(name, "gpu")) result = gpu(detail, size);
    else if (!strcmp(name, "printer")) result = printer(detail, size);
    else if (!strcmp(name, "smartcard")) result = smartcard(detail, size);
    else result = DEVPROBE_UNKNOWN;
    if (SUCCEEDED(com)) CoUninitialize();
    return result;
}
