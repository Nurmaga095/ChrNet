#include <winsock2.h>
#include <windows.h>

#include <initguid.h>

#include <fwpmu.h>
#include <rpc.h>

#include "wfp_guard.h"

#include <cstdio>
#include <vector>

#include "log.h"
#include "string_util.h"

namespace chrnet {

namespace {

// Weights inside the ChrNet sublayer. Every permit outranks every block, so
// the TUN, Xray and loopback keep working while the rest is filtered.
constexpr UINT8 kWeightPermitXray = 15;
constexpr UINT8 kWeightPermitTun = 14;
constexpr UINT8 kWeightPermitLoopback = 13;
constexpr UINT8 kWeightBlockDns = 10;
constexpr UINT8 kWeightBlockIpv6 = 9;

std::string WfpError(const char* what, DWORD status) {
  char code[16];
  snprintf(code, sizeof(code), "0x%08lX", static_cast<unsigned long>(status));
  return std::string(what) + " failed: " + code;
}

class FilterBuilder {
 public:
  FilterBuilder(HANDLE engine, const GUID& sublayer)
      : engine_(engine), sublayer_(sublayer) {}

  DWORD Add(const GUID& layer, const wchar_t* name, FWP_ACTION_TYPE action,
            UINT8 weight, std::vector<FWPM_FILTER_CONDITION0> conditions) {
    FWPM_FILTER0 filter = {};
    filter.displayData.name = const_cast<wchar_t*>(name);
    filter.layerKey = layer;
    filter.subLayerKey = sublayer_;
    filter.action.type = action;
    filter.weight.type = FWP_UINT8;
    filter.weight.uint8 = weight;
    filter.numFilterConditions = static_cast<UINT32>(conditions.size());
    filter.filterCondition = conditions.empty() ? nullptr : conditions.data();
    UINT64 id = 0;
    return FwpmFilterAdd0(engine_, &filter, nullptr, &id);
  }

 private:
  HANDLE engine_;
  GUID sublayer_;
};

FWPM_FILTER_CONDITION0 AppCondition(FWP_BYTE_BLOB* app_id) {
  FWPM_FILTER_CONDITION0 condition = {};
  condition.fieldKey = FWPM_CONDITION_ALE_APP_ID;
  condition.matchType = FWP_MATCH_EQUAL;
  condition.conditionValue.type = FWP_BYTE_BLOB_TYPE;
  condition.conditionValue.byteBlob = app_id;
  return condition;
}

FWPM_FILTER_CONDITION0 InterfaceCondition(UINT64* luid) {
  FWPM_FILTER_CONDITION0 condition = {};
  condition.fieldKey = FWPM_CONDITION_IP_LOCAL_INTERFACE;
  condition.matchType = FWP_MATCH_EQUAL;
  condition.conditionValue.type = FWP_UINT64;
  condition.conditionValue.uint64 = luid;
  return condition;
}

FWPM_FILTER_CONDITION0 LoopbackCondition() {
  FWPM_FILTER_CONDITION0 condition = {};
  condition.fieldKey = FWPM_CONDITION_FLAGS;
  condition.matchType = FWP_MATCH_FLAGS_ALL_SET;
  condition.conditionValue.type = FWP_UINT32;
  condition.conditionValue.uint32 = FWP_CONDITION_FLAG_IS_LOOPBACK;
  return condition;
}

FWPM_FILTER_CONDITION0 RemotePortCondition(uint16_t port) {
  FWPM_FILTER_CONDITION0 condition = {};
  condition.fieldKey = FWPM_CONDITION_IP_REMOTE_PORT;
  condition.matchType = FWP_MATCH_EQUAL;
  condition.conditionValue.type = FWP_UINT16;
  condition.conditionValue.uint16 = port;
  return condition;
}

FWPM_FILTER_CONDITION0 RemoteV6PrefixCondition(FWP_V6_ADDR_AND_MASK* prefix) {
  FWPM_FILTER_CONDITION0 condition = {};
  condition.fieldKey = FWPM_CONDITION_IP_REMOTE_ADDRESS;
  condition.matchType = FWP_MATCH_EQUAL;
  condition.conditionValue.type = FWP_V6_ADDR_MASK;
  condition.conditionValue.v6AddrMask = prefix;
  return condition;
}

}  // namespace

LeakGuard::~LeakGuard() { Remove(); }

bool LeakGuard::Install(const Options& options, std::string& error) {
  Remove();

  FWPM_SESSION0 session = {};
  session.displayData.name = const_cast<wchar_t*>(L"ChrNet");
  session.flags = FWPM_SESSION_FLAG_DYNAMIC;
  DWORD status =
      FwpmEngineOpen0(nullptr, RPC_C_AUTHN_WINNT, nullptr, &session, &engine_);
  if (status != ERROR_SUCCESS) {
    engine_ = nullptr;
    error = WfpError("FwpmEngineOpen0", status);
    return false;
  }

  status = FwpmTransactionBegin0(engine_, 0);
  if (status != ERROR_SUCCESS) {
    error = WfpError("FwpmTransactionBegin0", status);
    Remove();
    return false;
  }

  bool ok = false;
  FWP_BYTE_BLOB* app_id = nullptr;
  do {
    FWPM_SUBLAYER0 sublayer = {};
    if (UuidCreate(&sublayer.subLayerKey) != RPC_S_OK) {
      error = "UuidCreate failed";
      break;
    }
    sublayer.displayData.name =
        const_cast<wchar_t*>(L"ChrNet DNS leak protection");
    sublayer.weight = 0xFFFF;
    status = FwpmSubLayerAdd0(engine_, &sublayer, nullptr);
    if (status != ERROR_SUCCESS) {
      error = WfpError("FwpmSubLayerAdd0", status);
      break;
    }

    status = FwpmGetAppIdFromFileName0(options.xray_path.wstring().c_str(),
                                       &app_id);
    if (status != ERROR_SUCCESS) {
      error = WfpError("FwpmGetAppIdFromFileName0", status);
      break;
    }

    UINT64 tun_luid = options.tun_luid;
    FWP_V6_ADDR_AND_MASK global_unicast = {};
    global_unicast.addr[0] = 0x20;
    global_unicast.prefixLength = 3;

    FilterBuilder filters(engine_, sublayer.subLayerKey);
    const GUID layers[] = {FWPM_LAYER_ALE_AUTH_CONNECT_V4,
                           FWPM_LAYER_ALE_AUTH_CONNECT_V6};
    bool all_added = true;
    for (const auto& layer : layers) {
      const bool is_v6 =
          IsEqualGUID(layer, FWPM_LAYER_ALE_AUTH_CONNECT_V6) != FALSE;
      status = filters.Add(layer, L"ChrNet: permit Xray", FWP_ACTION_PERMIT,
                           kWeightPermitXray, {AppCondition(app_id)});
      if (status == ERROR_SUCCESS) {
        status = filters.Add(layer, L"ChrNet: permit tunnel",
                             FWP_ACTION_PERMIT, kWeightPermitTun,
                             {InterfaceCondition(&tun_luid)});
      }
      if (status == ERROR_SUCCESS) {
        status = filters.Add(layer, L"ChrNet: permit loopback",
                             FWP_ACTION_PERMIT, kWeightPermitLoopback,
                             {LoopbackCondition()});
      }
      if (status == ERROR_SUCCESS) {
        status = filters.Add(layer, L"ChrNet: block DNS outside tunnel",
                             FWP_ACTION_BLOCK, kWeightBlockDns,
                             {RemotePortCondition(options.dns_port)});
      }
      if (status == ERROR_SUCCESS && is_v6 && options.block_ipv6) {
        status = filters.Add(layer, L"ChrNet: block IPv6 outside tunnel",
                             FWP_ACTION_BLOCK, kWeightBlockIpv6,
                             {RemoteV6PrefixCondition(&global_unicast)});
      }
      if (status != ERROR_SUCCESS) {
        error = WfpError("FwpmFilterAdd0", status);
        all_added = false;
        break;
      }
    }
    if (!all_added) break;

    status = FwpmTransactionCommit0(engine_);
    if (status != ERROR_SUCCESS) {
      error = WfpError("FwpmTransactionCommit0", status);
      break;
    }
    ok = true;
  } while (false);

  if (app_id != nullptr) FwpmFreeMemory0(reinterpret_cast<void**>(&app_id));

  if (!ok) {
    FwpmTransactionAbort0(engine_);
    Remove();
    return false;
  }
  LogInfo("Leak protection filters installed");
  return true;
}

void LeakGuard::Remove() {
  if (engine_ == nullptr) return;
  // Closing a dynamic session deletes every object it added.
  FwpmEngineClose0(engine_);
  engine_ = nullptr;
  LogInfo("Leak protection filters removed");
}

}  // namespace chrnet
