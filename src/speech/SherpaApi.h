#pragma once

// -----------------------------------------------------------------------------
// SherpaApi: the sherpa-onnx C API (speech recognition, keyword spotting,
// voice activity, speaker embeddings), loaded at run time.
//
// Nothing loads with the app: Load() maps onnxruntime.dll and then
// sherpa-onnx-c-api.dll from one folder, both by full path (Windows ships an
// older onnxruntime.dll in System32, which must never be picked up), and
// fills the function table with GetProcAddress. It's called when the Bragi
// interface's voice starts, never before, so the other interfaces never
// load either library. Once loaded they stay mapped until the app exits
// (ONNX Runtime keeps global state and threads).
//
// The libraries are the sherpa-onnx 1.13.8 CPU build (MD runtime, without
// text to speech) with ONNX Runtime 1.28.2's GPU build, which runs on the
// processor until EnableCuda() adds the CUDA execution provider from the
// optional GPU pack (its onnxruntime_providers_cuda.dll and NVIDIA's
// libraries, in their own folder) in the same run. Load() refuses any other
// ONNX Runtime.
// -----------------------------------------------------------------------------

#include "sherpa-onnx/c-api/c-api.h"

#include <cstdint>
#include <string>

namespace gitgud::speech
{

#define GITGUD_SHERPA_FUNCS(X)                                                                     \
    X(SherpaOnnxGetVersionStr)                                                                     \
    X(SherpaOnnxCreateOfflineRecognizer)                                                           \
    X(SherpaOnnxDestroyOfflineRecognizer)                                                          \
    X(SherpaOnnxCreateOfflineStream)                                                               \
    X(SherpaOnnxCreateOfflineStreamWithHotwords)                                                   \
    X(SherpaOnnxDestroyOfflineStream)                                                              \
    X(SherpaOnnxAcceptWaveformOffline)                                                             \
    X(SherpaOnnxDecodeOfflineStream)                                                               \
    X(SherpaOnnxGetOfflineStreamResult)                                                            \
    X(SherpaOnnxDestroyOfflineRecognizerResult)                                                    \
    X(SherpaOnnxCreateKeywordSpotter)                                                              \
    X(SherpaOnnxDestroyKeywordSpotter)                                                             \
    X(SherpaOnnxCreateKeywordStreamWithKeywords)                                                   \
    X(SherpaOnnxIsKeywordStreamReady)                                                              \
    X(SherpaOnnxDecodeKeywordStream)                                                               \
    X(SherpaOnnxResetKeywordStream)                                                                \
    X(SherpaOnnxGetKeywordResult)                                                                  \
    X(SherpaOnnxDestroyKeywordResult)                                                              \
    X(SherpaOnnxDestroyOnlineStream)                                                               \
    X(SherpaOnnxOnlineStreamAcceptWaveform)                                                        \
    X(SherpaOnnxOnlineStreamInputFinished)                                                         \
    X(SherpaOnnxCreateVoiceActivityDetector)                                                       \
    X(SherpaOnnxDestroyVoiceActivityDetector)                                                      \
    X(SherpaOnnxVoiceActivityDetectorAcceptWaveform)                                               \
    X(SherpaOnnxVoiceActivityDetectorEmpty)                                                        \
    X(SherpaOnnxVoiceActivityDetectorDetected)                                                     \
    X(SherpaOnnxVoiceActivityDetectorPop)                                                          \
    X(SherpaOnnxVoiceActivityDetectorFront)                                                        \
    X(SherpaOnnxDestroySpeechSegment)                                                              \
    X(SherpaOnnxCreateSpeakerEmbeddingExtractor)                                                   \
    X(SherpaOnnxDestroySpeakerEmbeddingExtractor)                                                  \
    X(SherpaOnnxSpeakerEmbeddingExtractorDim)                                                      \
    X(SherpaOnnxSpeakerEmbeddingExtractorCreateStream)                                             \
    X(SherpaOnnxSpeakerEmbeddingExtractorIsReady)                                                  \
    X(SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding)                                         \
    X(SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding)

    struct SherpaApi
    {
#define GITGUD_SHERPA_DECLARE(name) decltype(&::name) name = nullptr;
        GITGUD_SHERPA_FUNCS(GITGUD_SHERPA_DECLARE)
#undef GITGUD_SHERPA_DECLARE
    };

    // The table, once Load() succeeded (every entry set).
    const SherpaApi& Sherpa();
    bool SherpaLoaded();

    // The ONNX Runtime version Load() accepts.
    inline constexpr const char* kOrtVersion = "1.28.2";

    // Whether `_Dir` holds the libraries (a file check: nothing is loaded).
    bool SherpaFilesPresent(const std::string& _Dir);

    // Load the libraries from `_Dir` (once; later calls report the first
    // outcome). False with `_Error` (a missing file, an export, another
    // ONNX Runtime already in the process, the wrong version). The engine
    // always loads them from the app's own voice folder.
    bool LoadSherpa(const std::string& _Dir, std::string& _Error);
    std::string SherpaDir();

    // Add the CUDA execution provider from the GPU pack in `_GpuDir`: its
    // NVIDIA libraries load first, by full path, then ONNX Runtime registers
    // onnxruntime_providers_cuda.dll from there by full path (nothing is
    // copied beside onnxruntime.dll and the search path is never changed).
    // Needs LoadSherpa first. Once it worked it stays (later calls say so);
    // a failure can be tried again (the pack repaired). False with `_Error`.
    bool EnableCuda(const std::string& _GpuDir, std::string& _Error);
    // EnableCuda worked: sessions can use CudaEpDevice().
    bool SherpaOnGpu();
    // For SessionOptionsAppendExecutionProvider_V2: the CUDA device (an
    // OrtEpDevice*) and the environment it was registered in (an OrtEnv*),
    // or nullptr before EnableCuda worked.
    const void* CudaEpDevice();
    void* CudaEnv();
    // Whether `_Dir` holds the GPU pack's provider (a file check).
    bool GpuRuntimePresent(const std::string& _Dir);

    // ONNX Runtime's API table (OrtApi, for `_uVersion`) from the loaded
    // onnxruntime.dll, for engines that use it directly; nullptr until
    // LoadSherpa succeeded.
    const void* OrtApiTable(std::uint32_t _uVersion);

} // namespace gitgud::speech
