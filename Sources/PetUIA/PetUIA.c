// UI Automation for pet-emit --jump: Swift's WinSDK module does not cover UIAutomationClient.h,
// so the few COM calls it takes live here, checked against the SDK's own header.
#include "PetUIA.h"

#ifdef _WIN32
#define COBJMACROS
#include <windows.h>
#include <ole2.h>
#include <UIAutomationClient.h>

#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "oleaut32.lib")

// Defined here rather than linked: the SDK only declares them.
static const CLSID kCUIAutomation =
    {0xff48dba4, 0x60ef, 0x4201, {0xaa, 0x87, 0x54, 0x10, 0x3e, 0xef, 0x59, 0x4e}};
static const IID kIUIAutomation =
    {0x30cbe57d, 0xd9d0, 0x452a, {0xab, 0x13, 0x7a, 0xc5, 0xac, 0x48, 0x25, 0xee}};
static const IID kIUIAutomationSelectionItemPattern =
    {0xa8efa66a, 0x0fda, 0x421a, {0x91, 0x94, 0x38, 0x02, 0x1f, 0x35, 0x78, 0xea}};

int pet_uia_select_tab(intptr_t window, const wchar_t *name, int timeout_ms, int retitle) {
    HRESULT init = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    int result = -1;
    IUIAutomation *uia = NULL;
    IUIAutomationElement *root = NULL, *tab = NULL;
    IUIAutomationCondition *byName = NULL, *isTab = NULL, *both = NULL;
    IUIAutomationSelectionItemPattern *item = NULL;
    VARIANT nameValue, typeValue;
    ULONGLONG deadline;
    VariantInit(&nameValue);
    VariantInit(&typeValue);

    if (FAILED(CoCreateInstance(&kCUIAutomation, NULL, CLSCTX_INPROC_SERVER, &kIUIAutomation, (void **)&uia)))
        goto done;
    if (FAILED(IUIAutomation_ElementFromHandle(uia, (UIA_HWND)window, &root)) || !root)
        goto done;

    nameValue.vt = VT_BSTR;
    nameValue.bstrVal = SysAllocString(name);
    typeValue.vt = VT_I4;
    typeValue.lVal = UIA_TabItemControlTypeId;
    if (!nameValue.bstrVal
        || FAILED(IUIAutomation_CreatePropertyCondition(uia, UIA_NamePropertyId, nameValue, &byName))
        || FAILED(IUIAutomation_CreatePropertyCondition(uia, UIA_ControlTypePropertyId, typeValue, &isTab))
        || FAILED(IUIAutomation_CreateAndCondition(uia, byName, isTab, &both)))
        goto done;

    result = 0;
    deadline = GetTickCount64() + (ULONGLONG)(timeout_ms > 0 ? timeout_ms : 0);
    for (;;) {
        if (retitle) SetConsoleTitleW(name);
        if (SUCCEEDED(IUIAutomationElement_FindFirst(root, TreeScope_Descendants, both, &tab)) && tab)
            break;
        if (GetTickCount64() >= deadline)
            goto done;
        Sleep(50);
    }
    if (SUCCEEDED(IUIAutomationElement_GetCurrentPatternAs(
            tab, UIA_SelectionItemPatternId, &kIUIAutomationSelectionItemPattern, (void **)&item))
        && item && SUCCEEDED(IUIAutomationSelectionItemPattern_Select(item)))
        result = 1;

done:
    if (item) IUIAutomationSelectionItemPattern_Release(item);
    if (tab) IUIAutomationElement_Release(tab);
    if (both) IUIAutomationCondition_Release(both);
    if (isTab) IUIAutomationCondition_Release(isTab);
    if (byName) IUIAutomationCondition_Release(byName);
    if (root) IUIAutomationElement_Release(root);
    if (uia) IUIAutomation_Release(uia);
    VariantClear(&nameValue);
    VariantClear(&typeValue);
    if (SUCCEEDED(init)) CoUninitialize();
    return result;
}

#else
int pet_uia_select_tab(intptr_t window, const wchar_t *name, int timeout_ms, int retitle) {
    (void)window; (void)name; (void)timeout_ms; (void)retitle;
    return -1;
}
#endif
