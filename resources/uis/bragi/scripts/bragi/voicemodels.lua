--- bragi/voicemodels.lua: the speech engine's models, Baldr's voice model,
-- the GPU libraries for NVIDIA GPUs, the voices made from recordings, and
-- setting the engine up with them.
--
-- The engine (gitgud.voiceEngine, C++) comes with the app; nothing else
-- does. Everything here is fetched only from the Bragi interface (the
-- welcome flow's voice step, or Settings), with its size shown first and
-- nothing downloaded until the user says so. It goes to the local app data
-- folder (gitgud.localDataPath("bragi/voice"): %LOCALAPPDATA%\Gitgud\bragi\voice
-- on Windows), each file checked against the size and SHA-256 pinned below.
--
-- Three groups of packages:
--   listen  the listening models (speech detection, the wake word spotter,
--           speech recognition, speaker recognition): voice needs them
--   turbo   Baldr's speech model, offered on every computer with the
--           engine: Chatterbox Turbo (Resemble AI, MIT), for replies in
--           Baldr, Bragi's own voice, or a voice made from a recording. It
--           runs on the processor (slow: the welcome flow says so) unless
--           the GPU libraries are in
--   gpu     the GPU libraries, offered only with an NVIDIA GPU whose driver
--           runs CUDA 13: ONNX Runtime's CUDA provider (from sherpa-onnx's
--           CUDA build, the same ONNX Runtime the app ships) and NVIDIA's
--           CUDA and cuDNN libraries, from NVIDIA's own packages on PyPI,
--           under NVIDIA's license terms. Baldr then runs on the GPU;
--           listening stays on the processor
--
-- Baldr comes with the interface (voices/baldr/ref.wav, the project's own
-- voice): once its model is in, its voice is made from that recording
-- without asking (the conditioning computed once and kept), and replies are
-- in Baldr unless another voice is chosen (Settings offers a Windows voice
-- for faster replies). Making your own voice is optional (Settings).
-- Without the model, replies use the voices Windows has.
--
--   bragi/voice/models/<package>/   the listening models, unpacked
--   bragi/voice/gpu/                the GPU libraries, together
--   bragi/voice/turbo/              Chatterbox Turbo's graphs and tokenizer
--   bragi/voice/voices/             voices made from recordings (<name>.voice,
--                                   and voices.json with their labels)
--   bragi/voice/downloads/          downloads in progress (resumed next time)
--   bragi/voice/staging/            archives being unpacked
--   bragi/voice/installed.json      { packages = { <id> = { at } } }
--   bragi/voice/voiceprints/        the user's voiceprint (enrollment)
--   bragi/voice/work/               the engine's own files (checks, config)
--
-- Install from a folder: the same files (the archives and wheels as
-- downloaded, or the models unpacked), for a computer that can't download
-- them.
--
-- The engine checks every model file's SHA-256 again before it loads it
-- (remembered by size and time). The listening models' install ends with a
-- self test: every model loaded and run once (gitgud.voiceSelfTest).
-- Chatterbox Turbo's quantized graphs are patched after download
-- (gitgud.onnxSetAccuracy: accuracy_level 4 on their quantized matmuls, many
-- times faster); the pinned SHA-256 is the patched graph's.
--
-- The app's ONNX Runtime is the GPU build, running on the processor. Once
-- the GPU libraries are in, the engine moves Baldr to the GPU the next time
-- it loads Baldr, in the same run (no restart); if the GPU doesn't start,
-- Baldr stays on the processor and Settings says why
-- (voiceEngine().gpuError). Voice never waits for the GPU.
--
-- Public API: voicemodels.PACKAGES, voicemodels.ENGINE,
-- voicemodels.TURBO, voicemodels.engineInstalled(), voicemodels.engine(),
-- voicemodels.installed(group), voicemodels.missing(group), voicemodels.packages(group),
-- voicemodels.gpu(), voicemodels.gpuSuitable(), voicemodels.turboReady(), voicemodels.turboOnGpu(),
-- voicemodels.gpuError(), voicemodels.configure(), voicemodels.state(),
-- voicemodels.install(groups), voicemodels.installFrom(folder, groups),
-- voicemodels.cancel(), voicemodels.check(), voicemodels.remove(group),
-- voicemodels.BALDR, voicemodels.ensureBaldr(), voicemodels.voices(),
-- voicemodels.makeVoice(wav, label, onDone, opts),
-- voicemodels.removeVoice(name), voicemodels.downloadBytes(list),
-- voicemodels.diskBytes(list), voicemodels.size(bytes), voicemodels.progressText(),
-- voicemodels.credits(), voicemodels.cards(opts), voicemodels.faultText(engine),
-- voicemodels.crashText(crash)
--
-- Publishes "bragi.voiceModels" (the state) when an install or a voice
-- moves on.

local app = require("core.app")

local voicemodels = { name = "bragi.voicemodels" }

local ROOT = "bragi/voice"
local MODELS = ROOT .. "/models"
local DOWNLOADS = ROOT .. "/downloads"
local STAGING = ROOT .. "/staging"
local VOICES = ROOT .. "/voices"
local VOICE_LABELS = VOICES .. "/voices.json"
local STATE_FILE = ROOT .. "/installed.json"

local RELEASE = "https://github.com/k2-fsa/sherpa-onnx/releases/download/"
local HUGGING_FACE = "https://huggingface.co/ResembleAI/chatterbox-turbo-ONNX/resolve/"
    .. "d21799bd0354adb85e348b8a0442a8405110a2cf/"
local PYPI = "https://files.pythonhosted.org/packages/"
local CUDA_ARCHIVE = "sherpa-onnx-v1.13.8-cuda-13.x-cudnn-9.x-onnxruntime1.28.2-win-x64-cuda"

-- One file picked out of an archive or wheel into the package's folder.
local function pick(from, to, size, sha256)
    return { from = from, to = to, size = size, sha256 = sha256 }
end

-- An NVIDIA wheel from PyPI (a zip): its DLLs into the GPU folder, and its
-- license beside them.
local function wheel(id, title, model, file, url, size, sha256, licenceName, picks)
    return { id = id, group = "gpu", title = title, model = model, credit = "NVIDIA", licence = licenceName,
        url = PYPI .. url .. file, archive = file, size = size, sha256 = sha256, dest = "gpu", pick = picks,
        licenceFile = { from = file:match("^(.-%-[%d%.]+)%-") .. ".dist-info/licenses/License.txt",
            to = "LICENSE-" .. id .. ".txt" } }
end

local function cu13(name)
    return "nvidia/cu13/bin/x86_64/" .. name
end

-- The packages, pinned (sherpa-onnx's stack;
-- Chatterbox Turbo for Baldr on every computer; the GPU libraries for
-- NVIDIA GPUs). Kinds:
--   file      downloaded as is into the package's folder
--   archive   unpacked; with `dir`, that folder becomes the package's; with
--             `pick`, those files go to `dest`
--   downloads several files into `dest`, then `patch` (graphs to patch)
-- `files`: what the engine loads, with sizes and SHA-256 (it checks them
-- before every first load).
voicemodels.PACKAGES = {
    { id = "vad", group = "listen", title = "Speech detection", about = "Tells speech from silence.",
      model = "Silero VAD",
      credit = "the Silero team", licence = "MIT",
      url = RELEASE .. "asr-models/silero_vad.onnx", file = "silero_vad.onnx",
      size = 643854, sha256 = "9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6",
      files = {
          { path = "silero_vad.onnx", size = 643854,
            sha256 = "9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6" },
      } },
    { id = "kws", group = "listen", title = "Wake word spotter", about = "Listens for Bragi's name.",
      model = "Zipformer keyword spotter (GigaSpeech, 3.3M)",
      credit = "the Next-gen Kaldi project", licence = "Apache-2.0",
      url = RELEASE .. "kws-models/sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01.tar.bz2",
      archive = "sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01.tar.bz2",
      dir = "sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01",
      size = 17626723, sha256 = "f170013b4716e41b62b9bfd809687c207cef798ef9bc6534d524e17af9b6561a",
      unpacked = 20100000,
      files = {
          { path = "encoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx", size = 4807159,
            sha256 = "1e721676515bcd42a186979733981213c66c80db680e1cc582dfedf3be76e678" },
          { path = "decoder-epoch-12-avg-2-chunk-16-left-64.onnx", size = 1063189,
            sha256 = "f61ebd3eed3773a44d088d53dfae92dbb6aec4839f4dcaee2d402414741663a3" },
          { path = "joiner-epoch-12-avg-2-chunk-16-left-64.int8.onnx", size = 163380,
            sha256 = "eae9da0c7e1e6c6a3f4cc42d167899c388f6c6701b94cb96320e4f55df79624c" },
          { path = "tokens.txt", size = 5006,
            sha256 = "fd2ded4050a55d2b1578870ba8697d02371980217806b7558bd0a5cc60f3ba53" },
          { path = "bpe.model", size = 244837,
            sha256 = "c8a2a0129c4ab8e463164c142f82d25649661b122c8cd0b7aab5c9e80b90ad24" },
      } },
    { id = "asr", group = "listen", title = "Speech recognition", about = "Turns what you say into text.",
      model = "Parakeet TDT 0.6B v2 (int8)",
      credit = "NVIDIA", licence = "CC-BY-4.0",
      url = RELEASE .. "asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8.tar.bz2",
      archive = "sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8.tar.bz2",
      dir = "sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8",
      size = 482468385, sha256 = "157c157bc51155e03e37d2466522a3a737dd9c72bb25f36eb18912964161e1ad",
      unpacked = 661400000,
      files = {
          { path = "encoder.int8.onnx", size = 652184296,
            sha256 = "a32b12d17bbbc309d0686fbbcc2987b5e9b8333a7da83fa6b089f0a2acd651ab" },
          { path = "decoder.int8.onnx", size = 7257753,
            sha256 = "b6bb64963457237b900e496ee9994b59294526439fbcc1fecf705b31a15c6b4e" },
          { path = "joiner.int8.onnx", size = 1739080,
            sha256 = "7946164367946e7f9f29a122407c3252b680dbae9a51343eb2488d057c3c43d2" },
          { path = "tokens.txt", size = 9384,
            sha256 = "ec182b70dd42113aff6c5372c75cac58c952443eb22322f57bbd7f53977d497d" },
      } },
    { id = "speaker", group = "listen", title = "Speaker recognition", about = "Tells your voice from others'.",
      model = "TitaNet-Large",
      credit = "NVIDIA", licence = "CC-BY-4.0",
      url = RELEASE .. "speaker-recongition-models/nemo_en_titanet_large.onnx", file = "nemo_en_titanet_large.onnx",
      size = 101405493, sha256 = "d51abcf31717ef28162f26acb9d44dd4127c3d44c9b8624f699f3425daca8e77",
      files = {
          { path = "nemo_en_titanet_large.onnx", size = 101405493,
            sha256 = "d51abcf31717ef28162f26acb9d44dd4127c3d44c9b8624f699f3425daca8e77" },
      } },

    -- The GPU libraries.
    { id = "gpu-engine", group = "gpu", title = "The GPU speech engine",
      model = "ONNX Runtime 1.28.2's CUDA provider (from sherpa-onnx 1.13.8's CUDA build)",
      credit = "Microsoft", licence = "MIT",
      url = RELEASE .. "v1.13.8/" .. CUDA_ARCHIVE .. ".tar.bz2", archive = CUDA_ARCHIVE .. ".tar.bz2",
      size = 478110488, sha256 = "1702e4a1ee68a07422469a7ec1d304a54b43a345ad888daf8e0b0257004a3273",
      dest = "gpu",
      -- Only the provider: the app's own voice folder has the matching
      -- onnxruntime.dll (the same build) and runs it from here.
      pick = {
          pick(CUDA_ARCHIVE .. "/lib/onnxruntime_providers_cuda.dll", "onnxruntime_providers_cuda.dll", 267632952,
              "26bce13391d2178c4fbb1ffeca6e828594ad1c1393c89f2a934bc977b0d1b5b7"),
      } },
    wheel("cuda-runtime", "The GPU runtime", "CUDA Runtime 13.4",
        "nvidia_cuda_runtime-13.4.92-py3-none-win_amd64.whl", "86/00/d5436004268f049214193659ebc36550b5ef3925c3d13b4cc980e13be6f5/",
        2778543, "08dca5e4aba480c2fd5b55075c0fa71b84ef9dcf0521f2d58baa14a803a7311c", "NVIDIA-CUDA", {
            pick(cu13("cudart64_13.dll"), "cudart64_13.dll", 551024,
                "d26fd1c2629594759af569a5252f94e4568d4ebeca67dc323834deb141aa278a"),
        }),
    wheel("cublas", "The GPU maths library", "cuBLAS 13.8",
        "nvidia_cublas-13.8.0.4-py3-none-win_amd64.whl", "a3/df/f1246959833e2c437db8be3e5b477f66b87f8817821ed40de6c7561c9a36/",
        423266897, "8c5494423bb8a46822cb6b0cb95d7fa4be2d7b96a31155dff083839ec8297910", "NVIDIA-CUDA", {
            pick(cu13("cublas64_13.dll"), "cublas64_13.dll", 54873200,
                "60bbba8868290311e9c1657b2193ddec667744eb555ff843f87acb7c039f9efa"),
            pick(cu13("cublasLt64_13.dll"), "cublasLt64_13.dll", 493474416,
                "cad63434448e7141629e240ea093ad596a7ef6a0f67b468ba9bc1df6e1eeee33"),
        }),
    wheel("cudnn", "The GPU neural network library", "cuDNN 9.27",
        "nvidia_cudnn_cu13-9.27.0.42-py3-none-win_amd64.whl", "87/6a/e55ff0ac26a5c6e2b21f41c9d04ad096b4ed6da593fba7e25845c61b0532/",
        436469905, "7d96f634adafd55c72231eb0500ca77ab109ec8ebff7b33000b76e081bc4558e", "NVIDIA-cuDNN", {
            pick("nvidia/cudnn/bin/cudnn64_9.dll", "cudnn64_9.dll", 270448,
                "0016bd73ac9192537ae5af6a3f05814316726dad1d1da44f113f0a9ef00ae34c"),
            pick("nvidia/cudnn/bin/cudnn_adv64_9.dll", "cudnn_adv64_9.dll", 105226864,
                "041cab1d6439d2558b4a7073a42dd95058d0395463ffb0d37275af11ec0af8d7"),
            pick("nvidia/cudnn/bin/cudnn_cnn64_9.dll", "cudnn_cnn64_9.dll", 1533040,
                "7dd1bcc6d8f00ad635f6a8a2cd076faba21626f3412e13c61a6bece3f88eacb1"),
            pick("nvidia/cudnn/bin/cudnn_engines_precompiled64_9.dll", "cudnn_engines_precompiled64_9.dll", 231660656,
                "5d9b829228ae18594dafedf718d9612606c8ce6d199aa7151bea53e863baeefe"),
            pick("nvidia/cudnn/bin/cudnn_engines_runtime_compiled64_9.dll", "cudnn_engines_runtime_compiled64_9.dll",
                39266928, "8e65eeb0a4a3b7afa48ea3ca71c4b88e355199f85485b6fc0badcc97ebc552ef"),
            pick("nvidia/cudnn/bin/cudnn_engines_tensor_ir64_9.dll", "cudnn_engines_tensor_ir64_9.dll", 156272,
                "51afb44ce4b901ccdac1434f9fc9d8d707b690f39ae1e2a6ffca98c5fd9dfa96"),
            pick("nvidia/cudnn/bin/cudnn_ext64_9.dll", "cudnn_ext64_9.dll", 130160,
                "a0e0e2e8e8e4678956bbef93fdccc4730bd5edf9b23d38bff49030ebba1940a6"),
            pick("nvidia/cudnn/bin/cudnn_graph64_9.dll", "cudnn_graph64_9.dll", 116132464,
                "ccc90435b2fd37b5ddd6a9fa0fd053ad8f46c2dc8b0a6256ef0ebea7f3efbace"),
            pick("nvidia/cudnn/bin/cudnn_heuristic64_9.dll", "cudnn_heuristic64_9.dll", 94795376,
                "c0439ee74a3dbec8ecf56fecbc6ac2506efcce702453e36119649545d02509c3"),
            pick("nvidia/cudnn/bin/cudnn_ops64_9.dll", "cudnn_ops64_9.dll", 37462128,
                "2bd7f4122eaeccb85538c2a6f7923d7254ad77d7b7149fed0a8139f1e3cf0b07"),
        }),
    wheel("cufft", "The GPU signal library", "cuFFT 12.4",
        "nvidia_cufft-12.4.0.43-py3-none-win_amd64.whl", "7b/cc/be7fe31058127336a66c88414a2ecc6beecf680baf85994a43eaf292b202/",
        160953139, "4ff7075f2d0b5f69291f70938d37a86ec632cbe5747184c74ba1f50f17accacc", "NVIDIA-CUDA", {
            pick(cu13("cufft64_12.dll"), "cufft64_12.dll", 232604272,
                "d353fd42da7729709864731f35888aa177793d2350e56557df4c6ebaaf079ace"),
        }),
    wheel("curand", "The GPU random number library", "cuRAND 10.4",
        "nvidia_curand-10.4.4.72-py3-none-win_amd64.whl", "e2/d4/f59ab342b82ff05ff27d674acd470ba625d788bf71338f7da6c89669d6b9/",
        56731059, "e0bce83e083ef25976ee74f59e8f067c15149a74538f1be6c2462e286e7c9c68", "NVIDIA-CUDA", {
            pick(cu13("curand64_10.dll"), "curand64_10.dll", 60045424,
                "2ae1d341cd7da1dab91e2215c62f627e0e0288ff54cdc9003e908746584b5b2b"),
        }),
    wheel("nvrtc", "The GPU compiler", "NVRTC 13.4",
        "nvidia_cuda_nvrtc-13.4.92-py3-none-win_amd64.whl", "64/5b/aa91896f64444eff1dd7f189f4db05046c7f0ba08c0f531283c1c1aac581/",
        46972283, "6af7ac5372920f6a7a560d0699348560fe44cb52c1d722d6afd3119f8af948c4", "NVIDIA-CUDA", {
            pick(cu13("nvrtc64_130_0.dll"), "nvrtc64_130_0.dll", 106038896,
                "c92027e5eae58b6f272cafb438bf59b55deb02bd326b183956e84e0a180dbd14"),
            pick(cu13("nvrtc-builtins64_134.dll"), "nvrtc-builtins64_134.dll", 7243376,
                "73768e90526e8a43d5eb356f0ffad198468e8c15e95d45a84c6c4b12fb9aa02f"),
        }),
    wheel("nvjitlink", "The GPU linker", "nvJitLink 13.4",
        "nvidia_nvjitlink-13.4.92-py3-none-win_amd64.whl", "72/7c/c44bd7277afafed9de262a23baec4dc8dcf7ecbb1b9ecb228821442d1e9b/",
        39053950, "b286f3a4f227a9363efdec263c7b91788cef1478d2b8a5fa8bab7f3e82ff82fd", "NVIDIA-CUDA", {
            pick(cu13("nvJitLink_130_0.dll"), "nvJitLink_130_0.dll", 97119344,
                "6044faf21b4979502588ff9319521dd21a42b9068239d3291e53bc5a063b09bf"),
        }),

    -- Baldr's speech model (all q4).
    { id = "turbo", group = "turbo", title = "Bragi's voice model", phrase = "Bragi's voice model",
      model = "Chatterbox Turbo (ONNX, q4)", credit = "Resemble AI", licence = "MIT",
      dest = "turbo", size = 724919508, unpacked = 728500000,
      downloads = {
          { url = HUGGING_FACE .. "tokenizer.json", file = "tokenizer.json", size = 3562272,
            sha256 = "3f04e34bea22f9144d1a19151154095bc9ce0430bf421304f5797e716288a906" },
          { url = HUGGING_FACE .. "onnx/embed_tokens_q4.onnx", file = "embed_tokens_q4.onnx", size = 2844,
            sha256 = "fd6ba1d22902e8f539d3dd6d7c1c44b98ebb4c84ebbb5e47fcb826ddcf667561" },
          { url = HUGGING_FACE .. "onnx/embed_tokens_q4.onnx_data", file = "embed_tokens_q4.onnx_data",
            size = 37286384, sha256 = "f54a51e234b509b64c3a03bb79e1149fba7e2eba6c2d9c222f18883379e1f5d8" },
          { url = HUGGING_FACE .. "onnx/language_model_q4.onnx", file = "language_model_q4.onnx", size = 274572,
            sha256 = "b39d03d3f8b943b9e60c6fce3fb41191dbc1df4589f913291db1e214eef669b1" },
          { url = HUGGING_FACE .. "onnx/language_model_q4.onnx_data", file = "language_model_q4.onnx_data",
            size = 204456572, sha256 = "2c029dc0acf48752473d8c74c72b5ceaaad76b9886fe106eaf2022142d5b5d5e" },
          { url = HUGGING_FACE .. "onnx/conditional_decoder_q4.onnx", file = "conditional_decoder_q4.onnx",
            size = 2179022, sha256 = "dccb7a6cea3472dc7f7d070eeb70ade18e6327fb4ec61a3d62cf211bfed90ea2" },
          { url = HUGGING_FACE .. "onnx/conditional_decoder_q4.onnx_data",
            file = "conditional_decoder_q4.onnx_data", size = 246397384,
            sha256 = "b5c5317e0b79a1a19dd3d5e2b2091ea06b15716716ab801a54eaeb906c6971ec" },
          { url = HUGGING_FACE .. "onnx/speech_encoder_q4.onnx", file = "speech_encoder_q4.onnx", size = 1200346,
            sha256 = "37956c20b67bed85a0da4bc83509d67b5969a1b257d1c546516a5236a17ad71e" },
          { url = HUGGING_FACE .. "onnx/speech_encoder_q4.onnx_data", file = "speech_encoder_q4.onnx_data",
            size = 229560112, sha256 = "58956db217c6443e49c91bdd54d7cf76b4a243f225c748b7bf746459fc27bc7d" },
      },
      patch = {
          { from = "embed_tokens_q4.onnx", to = "embed_tokens_q4acc4.onnx" },
          { from = "language_model_q4.onnx", to = "language_model_q4acc4.onnx" },
          { from = "conditional_decoder_q4.onnx", to = "conditional_decoder_q4acc4.onnx" },
          { from = "speech_encoder_q4.onnx", to = "speech_encoder_q4acc4.onnx" },
      },
      files = {
          { path = "tokenizer.json", size = 3562272,
            sha256 = "3f04e34bea22f9144d1a19151154095bc9ce0430bf421304f5797e716288a906" },
          { path = "embed_tokens_q4acc4.onnx", size = 2844,
            sha256 = "fd6ba1d22902e8f539d3dd6d7c1c44b98ebb4c84ebbb5e47fcb826ddcf667561" },
          { path = "embed_tokens_q4.onnx_data", size = 37286384,
            sha256 = "f54a51e234b509b64c3a03bb79e1149fba7e2eba6c2d9c222f18883379e1f5d8" },
          { path = "language_model_q4acc4.onnx", size = 277907,
            sha256 = "d84718f5e961cd63195f6555ae123b2c94a30d26c061ac562cacddd518aec1cb" },
          { path = "language_model_q4.onnx_data", size = 204456572,
            sha256 = "2c029dc0acf48752473d8c74c72b5ceaaad76b9886fe106eaf2022142d5b5d5e" },
          { path = "conditional_decoder_q4acc4.onnx", size = 2196180,
            sha256 = "208b1610264f8d4192adef3baf78985fdc8ddcc7de8ccb244c7f9aaf116a2d26" },
          { path = "conditional_decoder_q4.onnx_data", size = 246397384,
            sha256 = "b5c5317e0b79a1a19dd3d5e2b2091ea06b15716716ab801a54eaeb906c6971ec" },
          { path = "speech_encoder_q4acc4.onnx", size = 1202002,
            sha256 = "e8054f90b5b699ae178f9270486a96d7bec17803c357546c45756e09a63e34fb" },
          { path = "speech_encoder_q4.onnx_data", size = 229560112,
            sha256 = "58956db217c6443e49c91bdd54d7cf76b4a243f225c748b7bf746459fc27bc7d" },
      } },
}

-- A package's files on disk are its picks (gpu) or its listed files.
for _, p in ipairs(voicemodels.PACKAGES) do
    if p.pick and not p.files then
        p.files = {}
        local n = 0
        for _, f in ipairs(p.pick) do
            p.files[#p.files + 1] = { path = f.to, size = f.size, sha256 = f.sha256 }
            n = n + f.size
        end
        p.unpacked = n
    end
end

local LICENCE_LINKS = {
    ["MIT"] = "https://opensource.org/licenses/MIT",
    ["Apache-2.0"] = "https://www.apache.org/licenses/LICENSE-2.0",
    ["CC-BY-4.0"] = "https://creativecommons.org/licenses/by/4.0/",
    ["NVIDIA-CUDA"] = "https://docs.nvidia.com/cuda/eula/index.html",
    ["NVIDIA-cuDNN"] = "https://docs.nvidia.com/deeplearning/cudnn/latest/reference/eula.html",
}
local LICENCE_NAMES = {
    ["NVIDIA-CUDA"] = "NVIDIA CUDA Toolkit license",
    ["NVIDIA-cuDNN"] = "NVIDIA cuDNN license",
}

-- How the engine runs on this computer's processor (sherpa-onnx's CPU
-- stack, measured 2026-10): Parakeet on 4 threads with beam search biased
-- toward the wake word and the vocabulary; the spotter and detection on 1;
-- partial transcripts at most once a second; ONNX Runtime's threads don't
-- spin between calls. And what the wake word "Bragi" gets heard as.
voicemodels.ENGINE = {
    asrName = "parakeet-tdt-0.6b-v2-int8",
    asrThreads = 4,
    kwsThreads = 1,
    speakerThreads = 2,
    hotwords = true,
    hotwordsScore = 1.5,
    partialSeconds = 1.0,
    spinning = false,
    endBy = "app",
    wakeWord = "Bragi",
    spotterSpellings = { "Braggy", "Broggy" },
    mishearings = { "Braggy", "Braggie", "Broggy", "Braghi", "Brogi", "Bragy", "Bruggie", "Brogy", "Baragi",
        "Raghi", "Raggy", "Roggy", "Rogi", "Rogy", "Ruggy" },
}

-- Chatterbox Turbo's graphs, as the engine loads them: all q4 with
-- accuracy_level 4, the set the spike ran on both the GPU and the
-- processor (q8 was no faster on the processor, and is larger). On the
-- processor 8 threads were fastest (the spike: 3.5 times slower than real
-- time at 8 threads, 4.7 at 4); on the GPU the processor only feeds it. The
-- GPU libraries need a driver that runs CUDA 13, and memory for the models.
voicemodels.TURBO = {
    encoder = "speech_encoder_q4acc4.onnx",
    embed = "embed_tokens_q4acc4.onnx",
    lm = "language_model_q4acc4.onnx",
    decoder = "conditional_decoder_q4acc4.onnx",
    tokenizer = "tokenizer.json",
    cpuThreads = 8,
    gpuThreads = 4,
    minCuda = 13000,
    minMemory = 6e9,
}

-- Bragi's own voice: made from this recording (24 kHz mono, 17.6 s; the
-- voice server's reference) when Baldr's model is in. Spoken as the
-- server did: sentence by sentence, 1.15 times as fast with the pitch kept
-- (bragi.speechSpeed's default); Turbo has no exaggeration or CFG.
voicemodels.BALDR = {
    name = "baldr",
    label = "Baldr",
    recording = "voices/baldr/ref.wav",
    sha256 = "48a258b7220ceaaf7bbf607a02b29964965676d3b7efc52f64f7f68bb60c9c75",
}

-- What the engine was doing when a call failed (gitgud.voiceEngine's
-- lastCrash.call and fault messages), in words.
local CALLS = {
    ["load the recognizer"] = "loading the speech recognition model",
    ["load the keyword spotter"] = "loading the wake word spotter",
    ["load the speaker model"] = "loading the speaker recognition model",
    ["load the voice activity model"] = "loading the speech detection model",
    ["transcribe"] = "transcribing",
    ["spot the wake word"] = "listening for the wake word",
    ["start spotting"] = "listening for the wake word",
    ["detect speech"] = "listening",
    ["identify the speaker"] = "telling your voice from others",
    ["load the speech models"] = "loading the voice for replies",
    ["release the speech models"] = "releasing the voice for replies",
    ["make a voice"] = "making a voice from a recording",
    ["embed text"] = "speaking a reply",
    ["start a sentence"] = "speaking a reply",
    ["generate speech"] = "speaking a reply",
    ["decode speech"] = "speaking a reply",
}

local state = { phase = "idle" }
-- Where the rate for "time left" is measured from: { key, t, done }.
local rateFrom = nil
local wired = {}
local pending = {}
local cancelled = false
local making = nil -- { label } while a voice is being made, { error } after a failure

local function publish()
    app.publish("bragi.voiceModels", state)
end

--- Task events, wired once per name (they can't be unwired).
local function await(name, onDone, onProgress)
    pending[name] = { done = onDone, progress = onProgress }
    if wired[name] then
        return
    end
    wired[name] = true
    gitgud.on(name .. ".done", function(detail)
        local p = pending[name]
        pending[name] = nil
        if p then
            p.done(true, detail)
        end
    end)
    gitgud.on(name .. ".error", function(detail)
        local p = pending[name]
        pending[name] = nil
        if p then
            p.done(false, detail or "unknown error")
        end
    end)
    gitgud.on(name .. ".progress", function(detail)
        local p = pending[name]
        if p and p.progress then
            p.progress(gitgud.jsonDecode(detail or "") or {})
        end
    end)
end

-- ---------------------------------------------------------------------
-- What's there

--- gitgud.voiceEngine(): { installed, configured, loaded, faulted, faultCode,
-- fault, gpu, runtimeDir, turbo, test, lastCrash }. Tests swap it.
function voicemodels.engine()
    return gitgud.voiceEngine and gitgud.voiceEngine() or { installed = false }
end

--- The engine's libraries are in this build.
function voicemodels.engineInstalled()
    return voicemodels.engine().installed == true
end

local gpuInfo = nil

--- gitgud.gpuInfo(), asked once: { present, driver, cuda, devices = {
-- {name, memory} }, error }. Tests swap it.
function voicemodels.gpu()
    if not gpuInfo then
        gpuInfo = gitgud.gpuInfo and gitgud.gpuInfo() or { present = false, devices = {} }
    end
    return gpuInfo
end

--- The GPU libraries can run here: an NVIDIA GPU with enough memory whose
-- driver runs CUDA 13. Returns ok, and the GPU's name or why not.
function voicemodels.gpuSuitable()
    local g = voicemodels.gpu()
    if not g.present then
        return false, "no NVIDIA GPU was found" .. (g.error and (" (" .. tostring(g.error) .. ")") or "")
    end
    local best = nil
    for _, d in ipairs(g.devices or {}) do
        if not best or (d.memory or 0) > (best.memory or 0) then
            best = d
        end
    end
    if not best then
        return false, "the NVIDIA driver lists no GPU"
    end
    if (g.cuda or 0) < voicemodels.TURBO.minCuda then
        return false, "the NVIDIA driver (" .. tostring(g.driver) .. ") is too old: update it"
    end
    if (best.memory or 0) < voicemodels.TURBO.minMemory then
        return false, tostring(best.name) .. " has less than 6 GB of memory"
    end
    return true, tostring(best.name)
end

local function readState()
    local decoded = gitgud.jsonDecode(gitgud.localDataRead(STATE_FILE) or "")
    if type(decoded) ~= "table" or type(decoded.packages) ~= "table" then
        return { packages = {} }
    end
    return decoded
end

-- voicemodels.missing()'s answers, for a few seconds (voice.available()
-- asks often), and until the install state changes.
local cache = {}
local CACHE_MS = 5000

local function writeState(s)
    cache = {}
    return gitgud.localDataWrite(STATE_FILE, gitgud.jsonEncode(s))
end

local function packageDir(p)
    return p.dest and (ROOT .. "/" .. p.dest) or (MODELS .. "/" .. p.id)
end

--- A package whose install finished and whose files are all there, at
-- their sizes (the engine checks their SHA-256 before loading).
local function packageReady(p, s)
    if not (s.packages[p.id]) then
        return false
    end
    for _, f in ipairs(p.files) do
        local info = gitgud.localDataInfo(packageDir(p) .. "/" .. f.path)
        if not info or info.dir or info.size ~= f.size then
            return false
        end
    end
    return true
end

-- A group name or a list of them, as a set.
local function groupSet(groups)
    local set = {}
    if type(groups) == "table" then
        for _, g in ipairs(groups) do
            set[g] = true
        end
    else
        set[groups or "listen"] = true
    end
    return set
end

--- The packages of `groups` (a group or a list; default "listen").
function voicemodels.packages(groups)
    local set = groupSet(groups)
    local list = {}
    for _, p in ipairs(voicemodels.PACKAGES) do
        if set[p.group] then
            list[#list + 1] = p
        end
    end
    return list
end

--- The packages of `groups` not (completely) installed.
function voicemodels.missing(groups)
    if voicemodels.engine().test then
        return {}
    end
    local key = type(groups) == "table" and table.concat(groups, ",") or (groups or "listen")
    local now = gitgud.now()
    local hit = cache[key]
    if hit and now - hit.at < CACHE_MS then
        return hit.list
    end
    local s = readState()
    local list = {}
    for _, p in ipairs(voicemodels.packages(groups)) do
        if not packageReady(p, s) then
            list[#list + 1] = p
        end
    end
    cache[key] = { at = now, list = list }
    return list
end

--- Every package of `groups` is installed (the stand-in engine for tests
-- needs none). Default: the listening models.
function voicemodels.installed(groups)
    return #voicemodels.missing(groups) == 0
end

--- Replies can be spoken with Turbo (Baldr): its model is in (on the GPU
-- with the GPU libraries, else on the processor) and the engine runs.
function voicemodels.turboReady()
    if voicemodels.engine().test then
        return true
    end
    return voicemodels.engineInstalled() and voicemodels.installed("turbo") and not voicemodels.engine().faulted
end

--- Why Baldr isn't on the GPU although its libraries are in (the engine
-- tried and fell back to the processor), or nil.
function voicemodels.gpuError()
    local e = voicemodels.engine()
    if voicemodels.installed("gpu") and (e.gpuError or "") ~= "" then
        return e.gpuError
    end
    return nil
end

function voicemodels.downloadBytes(list)
    local n = 0
    for _, p in ipairs(list or voicemodels.packages()) do
        n = n + p.size
    end
    return n
end

function voicemodels.diskBytes(list)
    local n = 0
    for _, p in ipairs(list or voicemodels.packages()) do
        n = n + (p.unpacked or p.size)
    end
    return n
end

--- "2.4 GB", "602 MB", "17.6 MB", "644 KB".
function voicemodels.size(bytes)
    if bytes >= 1e9 then
        return string.format("%.1f GB", bytes / 1e9)
    elseif bytes >= 100e6 then
        return string.format("%d MB", math.floor(bytes / 1e6 + 0.5))
    elseif bytes >= 1e6 then
        return string.format("%.1f MB", bytes / 1e6)
    end
    return string.format("%d KB", math.floor(bytes / 1e3 + 0.5))
end

local function engineFiles(list)
    local files = {}
    for _, p in ipairs(list) do
        for _, f in ipairs(p.files) do
            files[#files + 1] = { path = gitgud.localDataPath(packageDir(p) .. "/" .. f.path), size = f.size,
                sha256 = f.sha256 }
        end
    end
    return files
end

--- Tell the engine where the models are (when they're installed), and
-- how to run: Turbo for replies, on the GPU when its libraries are in (the
-- engine moves it there in the same run). True when it took them.
function voicemodels.configure()
    if not voicemodels.engineInstalled() or not voicemodels.installed() then
        return false
    end
    local byId = {}
    for _, p in ipairs(voicemodels.PACKAGES) do
        byId[p.id] = p
    end
    local function path(p, file)
        return gitgud.localDataPath(packageDir(p) .. "/" .. file)
    end
    local settings = {}
    for k, v in pairs(voicemodels.ENGINE) do
        settings[k] = v
    end
    settings.vadModel = path(byId.vad, "silero_vad.onnx")
    settings.asrDir = gitgud.localDataPath(packageDir(byId.asr))
    settings.kwsDir = gitgud.localDataPath(packageDir(byId.kws))
    settings.speakerModel = path(byId.speaker, "nemo_en_titanet_large.onnx")
    settings.voiceprintsDir = gitgud.localDataPath(ROOT .. "/voiceprints")
    settings.workDir = gitgud.localDataPath(ROOT .. "/work")
    settings.files = engineFiles(voicemodels.packages("listen"))
    local gpu = voicemodels.installed("gpu")
    if gpu then
        settings.gpuDir = gitgud.localDataPath(ROOT .. "/gpu")
    end
    if voicemodels.installed("turbo") then
        -- On the GPU with its libraries (the engine falls back to the
        -- processor, with cpuThreads, if the GPU doesn't start).
        local t = voicemodels.TURBO
        settings.tts = {
            dir = gitgud.localDataPath(ROOT .. "/turbo"),
            encoder = t.encoder, embed = t.embed, lm = t.lm, decoder = t.decoder,
            tokenizer = gitgud.localDataPath(ROOT .. "/turbo/" .. t.tokenizer),
            voicesDir = gitgud.localDataPath(VOICES),
            threads = gpu and t.gpuThreads or t.cpuThreads,
            cpuThreads = t.cpuThreads,
            provider = gpu and "cuda" or "cpu",
            files = engineFiles(voicemodels.packages("turbo")),
        }
    end
    local ok = gitgud.voiceEngineSetup(settings)
    return ok == true
end

-- ---------------------------------------------------------------------
-- Installing

--- { phase = idle|download|verify|unpack|copy|patch|check|done|failed,
-- group, package, done, total, left, index, count, error, note }: done and
-- total are bytes (downloaded, hashed, read by the unpacker, copied,
-- patched); left is the milliseconds to go, once there's a rate.
function voicemodels.state()
    return state
end

local function set(fields)
    state = fields
    publish()
end

local function fail(message)
    set({ phase = "failed", group = state.group, error = tostring(message or "unknown error") })
end

-- "Speech detection" -> "speech detection"; "GPU libraries" stays.
local function lowerFirst(t)
    if t:sub(2, 2):match("%u") then
        return t
    end
    return t:sub(1, 1):lower() .. t:sub(2)
end

-- The phases with numbers, and their verbs.
local MEASURED = { download = "Downloading", verify = "Checking", unpack = "Unpacking", copy = "Copying",
    patch = "Preparing" }

--- "about 40 seconds", "about 3 minutes".
local function roughly(ms)
    local s = ms / 1000
    if s < 60 then
        return "about " .. math.max(5, math.floor(s / 5 + 0.5) * 5) .. " seconds"
    end
    local m = math.floor(s / 60 + 0.5)
    return m == 1 and "about a minute" or ("about " .. m .. " minutes")
end

--- The share done, 0 to 1, for the card's bar; nil while the step has no
-- numbers (the bar pulses then).
function voicemodels.progressFraction()
    local s = state
    if not MEASURED[s.phase] then
        return nil
    end
    -- A download knows its size before its first numbers come.
    local total = (s.total or 0) > 0 and s.total or (s.phase == "download" and s.package and s.package.size or 0)
    if total > 0 then
        return math.max(0, math.min(1, (s.done or 0) / total))
    end
    return nil
end

--- What the install is doing, in a line: the step, how far, and roughly
-- how long is left once there's a rate.
function voicemodels.progressText()
    local s = state
    local pkg = s.package or {}
    local p = pkg.phrase or lowerFirst(pkg.title or "")
    if MEASURED[s.phase] then
        local total = (s.total or 0) > 0 and s.total or 0
        local pct = total > 0 and math.floor((s.done or 0) * 100 / total) or 0
        local line = MEASURED[s.phase] .. " " .. p .. ": "
        if s.phase == "download" then
            local size = total > 0 and total or (pkg.size or 0)
            line = line .. string.format("%s of %s (%d%%)", voicemodels.size(s.done or 0), voicemodels.size(size),
                size > 0 and math.floor((s.done or 0) * 100 / size) or 0)
        else
            line = line .. pct .. "%"
        end
        if (s.count or 1) > 1 then
            line = line .. string.format(", %d of %d", s.index or 1, s.count)
        end
        if s.left then
            line = line .. ", " .. roughly(s.left) .. " left"
        end
        return line .. "."
    elseif s.phase == "check" then
        return "Loading every model once to check them."
    elseif s.phase == "done" then
        return s.note or "Installed and checked."
    elseif s.phase == "failed" then
        return "Didn't finish: " .. tostring(s.error) .. "."
    end
    return ""
end

local function markInstalled(p)
    local s = readState()
    s.packages[p.id] = { at = os.date("%Y-%m-%d %H:%M") }
    writeState(s)
end

--- After the listening models: tell the engine and have it load everything once.
local function selfTest()
    if not voicemodels.configure() then
        fail("the engine didn't take the models")
        return
    end
    set({ phase = "check", group = "listen" })
    local ok, err = gitgud.voiceSelfTest("BragiVoiceSelfTest")
    if not ok then
        fail(err)
        return
    end
    await("BragiVoiceSelfTest", function(_, detail)
        if state.phase ~= "check" then
            return -- stopped meanwhile
        end
        local result = gitgud.jsonDecode(detail or "") or {}
        if result.ok then
            set({ phase = "done", group = "listen", loadMs = result.loadMs })
            app.publish("bragi.voiceAvailable")
        else
            fail(result.message or result.code or "the self test failed")
        end
    end)
end

--- After Bragi's voice model or the GPU libraries: the engine takes them
-- in this run (Baldr moves to the GPU the next time it loads), and Baldr is
-- made.
local function packDone()
    voicemodels.configure()
    local note = "Installed. Bragi answers in Baldr, its own voice"
        .. (voicemodels.installed("gpu") and ", on the GPU." or ", on the processor: slower.")
    set({ phase = "done", group = state.group, note = note })
    app.publish("bragi.voiceAvailable")
    voicemodels.ensureBaldr()
end

-- Put an unpacked package in place: staging/<id>/<dir> -> models/<id>.
local function placeUnpacked(p, from)
    gitgud.localDataRemove(packageDir(p))
    local ok, err = gitgud.localDataMove(from, packageDir(p))
    gitgud.localDataRemove(STAGING .. "/" .. p.id)
    if not ok then
        return nil, err
    end
    markInstalled(p)
    return true
end

-- Move a package's picks out of its unpacked archive into its folder.
local function placePicks(p)
    local stage = STAGING .. "/" .. p.id
    for _, f in ipairs(p.pick) do
        local ok, err = gitgud.localDataMove(stage .. "/" .. f.from, packageDir(p) .. "/" .. f.to)
        if not ok then
            gitgud.localDataRemove(stage)
            return nil, (err or ("no " .. f.from .. " in the download"))
        end
    end
    if p.licenceFile then
        gitgud.localDataMove(stage .. "/" .. p.licenceFile.from, packageDir(p) .. "/" .. p.licenceFile.to)
    end
    gitgud.localDataRemove(stage)
    markInstalled(p)
    return true
end

-- A task's progress events ({phase, done, total}) into the state, with
-- the time left once two seconds of it give a rate.
local function progressFor(p, index, count)
    return function(progress)
        local phase = MEASURED[progress.phase or ""] and progress.phase or "download"
        local done = tonumber(progress.done) or 0
        local total = tonumber(progress.total) or 0
        local now = gitgud.now()
        local key = phase .. "|" .. tostring(p.id or p.title) .. "|" .. tostring(p.part or "")
        if not rateFrom or rateFrom.key ~= key or done < rateFrom.done then
            rateFrom = { key = key, t = now, done = done }
        end
        local left = nil
        local elapsed = now - rateFrom.t
        if elapsed >= 2000 and done > rateFrom.done and total > done then
            left = (total - done) / ((done - rateFrom.done) / elapsed)
        end
        if cancelled then
            return
        end
        state = { phase = phase, group = state.group, package = p, done = done, total = total, left = left,
            index = index, count = count }
        publish()
    end
end

-- A step starting: its phase with nothing done yet.
local function begin(phase, p)
    set({ phase = phase, group = state.group, package = p, done = 0, total = 0, index = state.index,
        count = state.count })
end

-- Unpack an archive (a local path) into place, then `onDone(ok, err)`.
local function unpack(p, archive, onDone)
    begin("unpack", p)
    local ok, err = gitgud.extractArchive("BragiVoiceUnpack", archive, STAGING .. "/" .. p.id)
    if not ok then
        onDone(false, err)
        return
    end
    await("BragiVoiceUnpack", function(done, detail)
        if not done then
            gitgud.localDataRemove(STAGING .. "/" .. p.id)
            onDone(false, detail)
            return
        end
        if p.pick then
            onDone(placePicks(p))
        else
            onDone(placeUnpacked(p, STAGING .. "/" .. p.id .. "/" .. p.dir))
        end
    end, progressFor(p, state.index, state.count))
end

-- Patch a downloaded package's graphs (on a worker, one by one), then
-- mark it installed and `onDone(ok, err)`.
local function patchGraphs(p, onDone)
    local index, count = state.index, state.count
    local i = 0
    local function nextGraph()
        i = i + 1
        local step = (p.patch or {})[i]
        if not step then
            for _, f in ipairs(p.files) do
                local info = gitgud.localDataInfo(packageDir(p) .. "/" .. f.path)
                if not info or info.size ~= f.size then
                    onDone(false, f.path .. " didn't come out as expected")
                    return
                end
            end
            markInstalled(p)
            onDone(true)
            return
        end
        if cancelled then
            onDone(false, "cancelled")
            return
        end
        local part = { id = p.id, title = p.title, phrase = p.phrase, part = i }
        state.index, state.count = index, count
        begin("patch", part)
        local from = gitgud.localDataPath(packageDir(p) .. "/" .. step.from)
        local to = gitgud.localDataPath(packageDir(p) .. "/" .. step.to)
        local ok, err = gitgud.onnxSetAccuracy(from, to, 4, "BragiVoicePatch")
        if not ok then
            onDone(false, err)
            return
        end
        await("BragiVoicePatch", function(done, detail)
            if not done then
                onDone(false, detail)
            else
                nextGraph()
            end
        end, progressFor(part, index, count))
    end
    nextGraph()
end


-- Download a package's files one by one into its folder, then patch.
local function fetchDownloads(p, onDone)
    local i = 0
    local index, count = state.index, state.count
    local function nextFile()
        i = i + 1
        local f = p.downloads[i]
        if not f then
            patchGraphs(p, onDone)
            return
        end
        local target = packageDir(p) .. "/" .. f.file
        -- A file only gets its name once its checksum passed: one there
        -- already (an earlier try) is done.
        local info = gitgud.localDataInfo(target)
        if info and info.size == f.size then
            nextFile()
            return
        end
        local ok, err = gitgud.downloadFile("BragiVoiceDownload", {
            url = f.url, file = target, sha256 = f.sha256, size = f.size })
        if not ok then
            onDone(false, err)
            return
        end
        await("BragiVoiceDownload", function(done, detail)
            if not done then
                onDone(false, detail)
                return
            end
            nextFile()
        end, progressFor({ id = p.id, title = p.title, phrase = p.phrase, size = f.size, part = i }, index, count))
    end
    nextFile()
end

-- Download one package and put it in place.
local function fetchOne(p, onDone)
    if p.downloads then
        fetchDownloads(p, onDone)
        return
    end
    local target = DOWNLOADS .. "/" .. (p.archive or p.file)
    local ok, err = gitgud.downloadFile("BragiVoiceDownload", {
        url = p.url, file = target, sha256 = p.sha256, size = p.size })
    if not ok then
        onDone(false, err)
        return
    end
    await("BragiVoiceDownload", function(done, detail)
        if not done then
            onDone(false, detail)
            return
        end
        if p.archive then
            unpack(p, detail, function(placed, why)
                if placed then
                    gitgud.localDataRemove(target)
                end
                onDone(placed, why)
            end)
        else
            gitgud.localDataRemove(packageDir(p))
            local moved, why = gitgud.localDataMove(target, packageDir(p) .. "/" .. p.file)
            if moved then
                markInstalled(p)
            end
            onDone(moved, why)
        end
    end, progressFor(p, state.index, state.count))
end

-- Run `step(p, onDone)` for each package in `list`, then `finish()`.
local function each(list, group, step, finish)
    cancelled = false
    local i = 0
    local function nextOne()
        if cancelled then
            set({ phase = "idle" })
            return
        end
        i = i + 1
        local p = list[i]
        if not p then
            finish()
            return
        end
        set({ phase = "download", group = group, package = p, done = 0, total = 0, index = i, count = #list })
        step(p, function(ok, err)
            if not ok then
                if cancelled or err == "cancelled" then
                    set({ phase = "idle" })
                else
                    fail(err)
                end
                return
            end
            nextOne()
        end)
    end
    nextOne()
end

local function busy()
    return state.phase ~= "idle" and state.phase ~= "done" and state.phase ~= "failed"
end

-- The finish for a set of groups: the listening models' self test, or the
-- pack's note.
local function finisher(groups)
    return groupSet(groups).listen and selfTest or packDone
end

-- Which card shows an install of `groups`.
local function installGroup(groups)
    local set = groupSet(groups)
    return set.listen and "listen" or (set.gpu and "gpu" or "turbo")
end

--- Download what's missing of `groups` (default "listen"; Baldr's model is
-- "turbo", the GPU libraries with it { "gpu", "turbo" }), the user having
-- said yes, then check it.
function voicemodels.install(groups)
    if busy() then
        return
    end
    local list = voicemodels.missing(groups)
    local group = installGroup(groups)
    if #list == 0 then
        finisher(groups)()
        return
    end
    each(list, group, fetchOne, finisher(groups))
end

local function joinPath(folder, ...)
    local sep = folder:find("\\", 1, true) and "\\" or "/"
    return table.concat({ folder, ... }, sep)
end

--- Find a package's files in `folder`: its download (archive or file), its
-- unpacked folder, or (several downloads) each file there or in onnx\.
local function findIn(folder, p)
    if p.downloads then
        local paths = {}
        for _, f in ipairs(p.downloads) do
            local here = joinPath(folder, f.file)
            local sub = joinPath(folder, "onnx", f.file)
            if gitgud.pathExists(here) then
                paths[#paths + 1] = here
            elseif gitgud.pathExists(sub) then
                paths[#paths + 1] = sub
            else
                return nil
            end
        end
        return { each = paths }
    end
    local name = p.archive or p.file
    if gitgud.pathExists(joinPath(folder, name)) then
        return { archive = joinPath(folder, name) }
    end
    if p.dir and gitgud.pathExists(joinPath(folder, p.dir, p.files[1].path)) then
        return { dir = joinPath(folder, p.dir) }
    end
    if not p.dir and p.file and gitgud.pathExists(joinPath(folder, p.id, p.file)) then
        return { archive = joinPath(folder, p.id, p.file) }
    end
    return nil
end

-- Copy each of a package's files from an unpacked folder.
local function copyFiles(p, dir, onDone)
    local i = 0
    local stage = STAGING .. "/" .. p.id .. "/" .. p.dir
    gitgud.localDataRemove(STAGING .. "/" .. p.id)
    local function nextFile()
        i = i + 1
        local f = p.files[i]
        if not f then
            onDone(placeUnpacked(p, stage))
            return
        end
        begin("copy", p)
        local ok, err = gitgud.copyToLocalData("BragiVoiceCopy", joinPath(dir, f.path), stage .. "/" .. f.path)
        if not ok then
            onDone(false, err)
            return
        end
        await("BragiVoiceCopy", function(done, detail)
            if not done then
                onDone(false, detail)
            else
                nextFile()
            end
        end, progressFor({ id = p.id, title = p.title, phrase = p.phrase, part = i }, state.index, state.count))
    end
    nextFile()
end

-- Check a file's SHA-256 and copy it in, then `onDone(ok, err)`.
local function checkAndCopy(p, source, sha256, target, onDone)
    local index, count = state.index, state.count
    begin("verify", p)
    local ok, err = gitgud.fileSha256("BragiVoiceHash", source)
    if not ok then
        onDone(false, err)
        return
    end
    await("BragiVoiceHash", function(done, sha)
        if not done then
            onDone(false, sha)
            return
        end
        if tostring(sha):lower() ~= sha256 then
            onDone(false, source .. " isn't the expected file")
            return
        end
        begin("copy", p)
        local copied, why = gitgud.copyToLocalData("BragiVoiceCopy", source, target)
        if not copied then
            onDone(false, why)
            return
        end
        await("BragiVoiceCopy", function(c, detail)
            onDone(c, not c and detail or nil)
        end, progressFor(p, index, count))
    end, progressFor(p, index, count))
end

--- Install from files already on this computer (the same downloads, or
-- the models unpacked). Packages not found there stay missing.
function voicemodels.installFrom(folder, groups)
    if busy() or type(folder) ~= "string" or folder == "" then
        return
    end
    local found, list = {}, {}
    for _, p in ipairs(voicemodels.missing(groups)) do
        local where = findIn(folder, p)
        if where then
            found[p.id] = where
            list[#list + 1] = p
        end
    end
    local group = installGroup(groups)
    state.group = group
    if #list == 0 then
        fail("none of the files are in " .. folder)
        return
    end
    each(list, group, function(p, onDone)
        local where = found[p.id]
        if where.dir then
            copyFiles(p, where.dir, onDone)
            return
        end
        if where.each then
            local i = 0
            local function nextFile()
                i = i + 1
                local f = p.downloads[i]
                if not f then
                    patchGraphs(p, onDone)
                    return
                end
                checkAndCopy({ id = p.id, title = p.title, phrase = p.phrase, part = i }, where.each[i], f.sha256, packageDir(p) .. "/" .. f.file, function(ok, err)
                    if not ok then
                        onDone(false, err)
                    else
                        nextFile()
                    end
                end)
            end
            nextFile()
            return
        end
        if p.archive then
            -- Checked, then unpacked straight from the folder.
            begin("verify", p)
            local ok, err = gitgud.fileSha256("BragiVoiceHash", where.archive)
            if not ok then
                onDone(false, err)
                return
            end
            await("BragiVoiceHash", function(done, sha)
                if not done then
                    onDone(false, sha)
                elseif tostring(sha):lower() ~= p.sha256 then
                    onDone(false, (p.archive or p.file) .. " in that folder isn't the expected file")
                else
                    unpack(p, where.archive, onDone)
                end
            end, progressFor(p, state.index, state.count))
            return
        end
        gitgud.localDataRemove(packageDir(p))
        checkAndCopy(p, where.archive, p.sha256, packageDir(p) .. "/" .. p.file, function(ok, err)
            if ok then
                markInstalled(p)
            end
            onDone(ok, err)
        end)
    end, finisher(groups))
end

-- The install's tasks that Stop can end.
local TASKS = { "BragiVoiceDownload", "BragiVoiceHash", "BragiVoiceCopy", "BragiVoiceUnpack" }

--- Stop the install: the running step ends (a download is kept for next
-- time; a half-done copy or unpack is removed) and nothing more starts.
-- The card goes back to its offer at once.
function voicemodels.cancel()
    cancelled = true
    for _, task in ipairs(TASKS) do
        gitgud.downloadCancel(task)
    end
    set({ phase = "idle" })
end

--- Check the installed models again: the engine loads and runs them.
function voicemodels.check()
    if busy() then
        return
    end
    selfTest()
end

--- Remove a group (default "listen": the listening models, the engine's
-- files and downloads in progress too; "turbo": Baldr's model; "gpu": the
-- GPU libraries).
function voicemodels.remove(group)
    if busy() then
        return
    end
    require("bragi.voice").stop()
    gitgud.voiceEngineRelease()
    local s = readState()
    if (group or "listen") == "listen" then
        gitgud.localDataRemove(MODELS)
        gitgud.localDataRemove(STAGING)
        gitgud.localDataRemove(DOWNLOADS)
        gitgud.localDataRemove(ROOT .. "/work")
        for _, p in ipairs(voicemodels.packages("listen")) do
            s.packages[p.id] = nil
        end
    else
        -- The runtime may be loaded: what Windows won't delete now goes
        -- next time (the files are no longer listed as installed).
        gitgud.localDataRemove(ROOT .. "/" .. group)
        for _, p in ipairs(voicemodels.packages(group)) do
            s.packages[p.id] = nil
        end
    end
    writeState(s)
    voicemodels.configure()
    set({ phase = "idle" })
    app.publish("bragi.voiceAvailable")
end

-- ---------------------------------------------------------------------
-- Voices made from recordings

local function voiceLabels()
    local decoded = gitgud.jsonDecode(gitgud.localDataRead(VOICE_LABELS) or "")
    return type(decoded) == "table" and decoded or {}
end

--- The voices made here: { { id = "turbo:<name>", name = label, file,
-- builtin }, ... }: Baldr first, then the others in the order they were
-- made. A voice counts once its file is there (with the stand-in engine for
-- tests, once it's recorded as made).
function voicemodels.voices()
    local labels = voiceLabels()
    local test = voicemodels.engine().test
    local list = {}
    for name, entry in pairs(labels) do
        if type(entry) == "table" and (test or gitgud.localDataInfo(VOICES .. "/" .. name .. ".voice")) then
            list[#list + 1] = { id = "turbo:" .. name, name = entry.label or name, at = entry.at or "", file = name,
                builtin = name == voicemodels.BALDR.name }
        end
    end
    table.sort(list, function(a, b)
        if a.builtin ~= b.builtin then
            return a.builtin
        end
        return a.at == b.at and a.name < b.name or a.at < b.at
    end)
    return list
end

-- The interface's own copy of a file (the interface folder, or the app's).
local function interfaceFile(relative)
    for _, root in ipairs(require("bragi.customize").roots()) do
        if root and gitgud.pathExists(root .. "/" .. relative) then
            return root .. "/" .. relative
        end
    end
    return nil
end

local baldrTried = false

--- Make Baldr if its model is in and Baldr isn't made yet (once a
-- run; quietly). Called when the pack finishes, and when voice starts.
function voicemodels.ensureBaldr()
    local b = voicemodels.BALDR
    if baldrTried or not voicemodels.turboReady() then
        return
    end
    for _, v in ipairs(voicemodels.voices()) do
        if v.file == b.name then
            return
        end
    end
    local recording = interfaceFile(b.recording)
    if not recording then
        return
    end
    baldrTried = true
    voicemodels.makeVoice(recording, b.label, nil, { name = b.name, builtin = true })
end

--- The voice being made, or why making it failed: { label } / { error }.
function voicemodels.making()
    return making
end

-- A file name for a label: lowercase letters, digits, and dashes.
local function slug(label)
    local s = tostring(label):lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
    s = s:sub(1, 40)
    return s ~= "" and s or "voice"
end

--- Make a voice from a recording (a WAV file, 10 to 20 s of one person
-- speaking clearly): its conditioning is computed once and kept; the
-- recording isn't copied. `onDone(ok, message)`.
function voicemodels.makeVoice(wav, label, onDone, opts)
    opts = opts or {}
    if making and making.label then
        return
    end
    label = tostring(label or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if label == "" then
        label = "My voice"
    end
    local name = opts.name or slug(label)
    if not opts.builtin and name == voicemodels.BALDR.name then
        name = name .. "-2" -- Baldr's own name stays Baldr's
    end
    voicemodels.configure()
    local ok, err = gitgud.voiceMakeVoice("BragiVoiceMake", wav, name)
    if not ok then
        making = { error = err }
        publish()
        if onDone then
            onDone(false, err)
        end
        return
    end
    making = { label = label, builtin = opts.builtin }
    publish()
    await("BragiVoiceMake", function(_, detail)
        local result = gitgud.jsonDecode(detail or "") or {}
        if result.ok then
            local labels = voiceLabels()
            labels[name] = { label = label, at = os.date("%Y-%m-%d %H:%M:%S"), seconds = result.seconds }
            gitgud.localDataWrite(VOICE_LABELS, gitgud.jsonEncode(labels))
            making = nil
            -- A voice you made is the one replies use; Baldr is the
            -- default without being chosen.
            if not opts.builtin then
                require("core.settings").set("bragi.voice", "turbo:" .. name)
            end
        else
            making = { error = result.message or result.code or "it didn't work" }
        end
        publish()
        app.publish("bragi.voicesChanged")
        if onDone then
            onDone(result.ok == true, result.ok and label or making.error)
        end
    end)
end

--- Remove a made voice (by its file name).
function voicemodels.removeVoice(name)
    gitgud.localDataRemove(VOICES .. "/" .. name .. ".voice")
    local labels = voiceLabels()
    labels[name] = nil
    gitgud.localDataWrite(VOICE_LABELS, gitgud.jsonEncode(labels))
    local settings = require("core.settings")
    if settings.get("bragi.voice", "") == "turbo:" .. name then
        settings.set("bragi.voice", "")
    end
    publish()
    app.publish("bragi.voicesChanged")
end

-- ---------------------------------------------------------------------
-- Cards (bragiSettings.cards rows), for the welcome flow and Settings

local function pickFolder(groups)
    return function()
        local folder = gitgud.pickFolder("The folder with the downloaded files")
        if folder and folder ~= "" then
            voicemodels.installFrom(folder, groups)
        end
    end
end

local function pickRecording()
    local wav = gitgud.pickFile and gitgud.pickFile("A recording of the voice", "Recordings (WAV)", "*.wav")
    if wav and wav ~= "" then
        local label = wav:match("([^/\\]+)%.[Ww][Aa][Vv]$") or "My voice"
        voicemodels.makeVoice(wav, label)
    end
end

-- An install's rows: the step with its bar (bragi/settings.lua's
-- "progress" row: a bar from progressFraction, pulsing while a step has no
-- numbers), and Stop while a step can stop.
local function progressRows(rows, s)
    rows[#rows + 1] = { kind = "progress", title = "Installing", sub = voicemodels.progressText,
        fraction = voicemodels.progressFraction }
    if MEASURED[s.phase] then
        rows[#rows + 1] = { kind = "action", title = "Stop", sub = "What's downloaded is kept for next time.",
            button = "Stop", run = voicemodels.cancel }
    end
end

local function listenCard(opts)
    local s = state
    local rows = {}
    local working = busy() and s.group == "listen"
    local missing = voicemodels.missing()
    local card = { heading = "Voice models", rows = rows }
    if working then
        progressRows(rows, s)
        rows[1].title = "Installing the voice models"
        card.progress = true
    elseif #missing > 0 then
        local where = gitgud.localDataPath(ROOT)
        local partly = #missing < #voicemodels.packages("listen")
        rows[#rows + 1] = { kind = "info", title = partly and "Some voice models are missing" or "Voice models",
            sub = "Bragi hears you with speech models that run on this computer: nothing you say leaves it. "
                .. "They're about " .. voicemodels.size(voicemodels.downloadBytes(missing)) .. " to download and "
                .. voicemodels.size(voicemodels.diskBytes(missing)) .. " on disk, in " .. where
                .. ". Nothing is downloaded until you choose to." }
        for _, p in ipairs(missing) do
            rows[#rows + 1] = { kind = "info", title = p.title .. ", " .. voicemodels.size(p.size), sub = p.about }
        end
        if s.phase == "failed" and s.group == "listen" then
            rows[#rows + 1] = { kind = "info", title = "The last try didn't finish", sub = tostring(s.error) .. "." }
        end
        rows[#rows + 1] = { kind = "action", title = "Download them",
            sub = voicemodels.size(voicemodels.downloadBytes(missing)) .. ", from the models' publishers.",
            button = s.phase == "failed" and s.group == "listen" and "Try again" or "Download", primary = true,
            run = function()
                voicemodels.install("listen")
            end }
        rows[#rows + 1] = { kind = "action", title = "Install from a folder",
            sub = "The same files, downloaded already.", button = "Choose folder", run = pickFolder("listen") }
    else
        local sub = (s.phase == "done" and s.group == "listen") and "Installed and checked: every model loaded and ran."
            or "Installed in " .. gitgud.localDataPath(MODELS) .. "."
        if s.phase == "failed" and s.group == "listen" then
            sub = "The check didn't pass: " .. tostring(s.error) .. "."
        end
        rows[#rows + 1] = { kind = "info", title = "Voice models", sub = sub }
        if opts.settings then
            rows[#rows + 1] = { kind = "action", title = "Check them",
                sub = "Load and run every model once.", button = "Check", run = voicemodels.check }
            rows[#rows + 1] = { kind = "action", title = "Repair",
                sub = "Remove them and download them again.", button = "Repair", run = function()
                    voicemodels.remove("listen")
                    voicemodels.install("listen")
                end }
            rows[#rows + 1] = { kind = "action", title = "Remove them",
                sub = "Frees " .. voicemodels.size(voicemodels.diskBytes()) .. ". Voice is off without them.",
                button = "Remove", run = function()
                    voicemodels.remove("listen")
                end }
        end
    end
    local settings = require("core.settings")
    local off = settings.get("bragi.voiceOff", "")
    if opts.settings and off ~= "" then
        rows[#rows + 1] = { kind = "action", title = "Voice is off", sub = off, button = "Turn on",
            run = function()
                require("bragi.voice").clearCrash()
                publish()
            end }
    end
    return card
end

-- Where Turbo runs: where the engine loaded it, else the GPU when its
-- libraries are in and didn't fail to start.
function voicemodels.turboOnGpu()
    local e = voicemodels.engine()
    if (e.turboDevice or "") ~= "" then
        return e.turboDevice == "gpu"
    end
    return voicemodels.installed("gpu") and (e.gpuError or "") == ""
end

-- The Baldr card: the Turbo voice model, offered on every computer with
-- the engine (on the processor without a suitable NVIDIA GPU: slower).
local function turboCard(opts)
    local s = state
    local rows = {}
    local card = { heading = "Baldr, Bragi's voice", rows = rows }
    local missing = voicemodels.missing("turbo")
    local gpuOk = voicemodels.gpuSuitable()
    if busy() and s.group == "turbo" then
        progressRows(rows, s)
        rows[1].title = "Installing Bragi's voice"
        card.progress = true
    elseif #missing > 0 then
        local size = voicemodels.size(voicemodels.downloadBytes(missing))
        local sub
        local made = "Bragi can answer in Baldr, its own voice. The voice comes with the app as a recording; a "
            .. "speech model makes Baldr from it and speaks it, all on this computer"
        if gpuOk then
            sub = made .. ", on your NVIDIA GPU with the GPU libraries below. The model is about " .. size
                .. " to download."
        else
            sub = made .. ". This computer has no NVIDIA GPU it can use, so the model runs on the processor and "
                .. "Baldr is slow here: a reply's first words take about 5 to 10 seconds, and long replies fall "
                .. "behind. The model is about " .. size .. " to download. The Windows voices answer at once; you "
                .. "can skip this."
        end
        rows[#rows + 1] = { kind = "info", title = "Replies in Baldr, Bragi's own voice", sub = sub }
        if s.phase == "failed" and s.group == "turbo" then
            rows[#rows + 1] = { kind = "info", title = "The last try didn't finish", sub = tostring(s.error) .. "." }
        end
        rows[#rows + 1] = { kind = "action", title = "Download Bragi's voice",
            sub = size .. ". Bragi then makes its Baldr voice on this computer.",
            button = s.phase == "failed" and s.group == "turbo" and "Try again" or "Download", primary = gpuOk,
            run = function()
                voicemodels.install("turbo")
            end }
        rows[#rows + 1] = { kind = "action", title = "Install from a folder",
            sub = "The same files, downloaded already.", button = "Choose folder", run = pickFolder("turbo") }
    else
        local sub
        if making and making.builtin then
            sub = "Installed. Making Baldr from its recording: the first time loads the voice model, about a minute."
        elseif voicemodels.gpuError() then
            sub = "Installed. Bragi answers in Baldr on the processor: the GPU didn't start ("
                .. voicemodels.gpuError() .. ")."
        elseif voicemodels.turboOnGpu() then
            sub = "Installed. Bragi answers in Baldr, its own voice, on the GPU."
        else
            sub = "Installed. Bragi answers in Baldr, its own voice, on the processor: slower than the Windows voices."
        end
        -- While Baldr is being made there are no numbers: the bar pulses.
        rows[#rows + 1] = { kind = (making and making.builtin) and "progress" or "info", title = "Baldr", sub = sub,
            fraction = function()
                return nil
            end }
        if opts.settings then
            rows[#rows + 1] = { kind = "action", title = "Remove the voice model",
                sub = "Frees " .. voicemodels.size(voicemodels.diskBytes(voicemodels.packages("turbo")))
                    .. ". Replies use the Windows voices.",
                button = "Remove", run = function()
                    voicemodels.remove("turbo")
                end }
        end
    end
    return card
end

-- The GPU card: NVIDIA's libraries and the engine's CUDA build, only with a
-- suitable NVIDIA GPU (in Settings, also to say why not).
local function gpuCard(opts)
    local ok, gpuName = voicemodels.gpuSuitable()
    local rows = {}
    local card = { heading = "Faster with your NVIDIA GPU", rows = rows }
    if not ok and not voicemodels.installed("gpu") then
        if not opts.settings then
            return nil
        end
        rows[#rows + 1] = { kind = "info", title = "Not for this computer",
            sub = "Baldr runs on an NVIDIA GPU with at least 6 GB of memory and an up-to-date driver: "
                .. gpuName .. ". It runs on the processor instead." }
        return card
    end
    local s = state
    local missing = voicemodels.missing({ "gpu", "turbo" })
    local gpuPart = voicemodels.missing("gpu")
    if busy() and s.group == "gpu" then
        progressRows(rows, s)
        rows[1].title = "Installing the GPU libraries"
        card.progress = true
    elseif #gpuPart > 0 then
        rows[#rows + 1] = { kind = "info", title = "Baldr on " .. gpuName,
            sub = "With the GPU libraries, Baldr answers about as fast as you read. About "
                .. voicemodels.size(voicemodels.downloadBytes(missing)) .. " to download"
                .. (#missing > #gpuPart and " with Bragi's voice model" or "") .. ": the GPU speech engine and "
                .. "NVIDIA's GPU libraries, under NVIDIA's license terms. Nothing is downloaded until you choose to." }
        if s.phase == "failed" and s.group == "gpu" then
            rows[#rows + 1] = { kind = "info", title = "The last try didn't finish", sub = tostring(s.error) .. "." }
        end
        rows[#rows + 1] = { kind = "action", title = "Download the GPU libraries",
            sub = voicemodels.size(voicemodels.downloadBytes(gpuPart)) .. ", then Bragi's voice model if it isn't in.",
            button = s.phase == "failed" and s.group == "gpu" and "Try again" or "Download", primary = true,
            run = function()
                voicemodels.install({ "gpu", "turbo" })
            end }
        rows[#rows + 1] = { kind = "action", title = "Install from a folder",
            sub = "The same files, downloaded already.", button = "Choose folder",
            run = pickFolder({ "gpu", "turbo" }) }
    else
        local why = voicemodels.gpuError()
        rows[#rows + 1] = { kind = "info", title = "GPU libraries", sub = why
            and ("Installed, but the GPU didn't start: " .. why .. ". Baldr runs on the processor.")
            or ("Installed. Baldr runs on " .. gpuName .. ".") }
        if opts.settings then
            rows[#rows + 1] = { kind = "action", title = "Remove them",
                sub = "Frees " .. voicemodels.size(voicemodels.diskBytes(voicemodels.packages("gpu")))
                    .. ". Baldr runs on the processor.",
                button = "Remove", run = function()
                    voicemodels.remove("gpu")
                end }
        end
    end
    return card
end

-- The system's first voice, for "use a Windows voice".
local function windowsVoice()
    local list = gitgud.voiceVoices and gitgud.voiceVoices() or nil
    return type(list) == "table" and list[1] and list[1].id or nil
end

-- Settings: the voice replies use (Baldr by default), the switch to a
-- Windows voice, and making your own (optional).
local function voicesCard(opts)
    if not voicemodels.turboReady() then
        return nil
    end
    local settings = require("core.settings")
    local chosen = settings.get("bragi.voice", "")
    local onWindows = chosen ~= "" and not chosen:find("^turbo:")
    local rows = {}
    local card = { heading = "Voice for replies", rows = rows }
    local list = voicemodels.voices()
    local where = voicemodels.turboOnGpu() and "on the GPU" or "on the processor, slower"
    for _, v in ipairs(list) do
        if v.builtin then
            rows[#rows + 1] = { kind = "info", title = v.name,
                sub = "Bragi's own voice, " .. where .. "."
                    .. ((chosen == "" or chosen == v.id) and " Replies use it." or "") }
        elseif opts.settings then
            rows[#rows + 1] = { kind = "action", title = v.name,
                sub = "Made from a recording, " .. where .. "." .. (chosen == v.id and " Replies use it." or ""),
                button = "Remove", run = function()
                    voicemodels.removeVoice(v.file)
                end }
        end
    end
    if onWindows then
        rows[#rows + 1] = { kind = "action", title = "Replies use a Windows voice",
            sub = "Instant, but not Baldr.", button = "Use Baldr", run = function()
                settings.set("bragi.voice", "")
                app.publish("bragi.voicesChanged")
            end }
    else
        rows[#rows + 1] = { kind = "action", title = "Faster replies: use a Windows voice",
            sub = "The voices Windows has answer at once.", button = "Use Windows voice", run = function()
                local id = windowsVoice()
                if id then
                    settings.set("bragi.voice", id)
                    app.publish("bragi.voicesChanged")
                end
            end }
    end
    if making and making.label then
        -- No numbers to show while the model loads and listens: the bar pulses.
        rows[#rows + 1] = { kind = "progress", title = "Making " .. making.label,
            sub = "The first time loads the voice model: it can take a minute.", fraction = function()
                return nil
            end }
    else
        if making and making.error then
            rows[#rows + 1] = { kind = "info", title = "That recording didn't work", sub = tostring(making.error) .. "." }
        end
        rows[#rows + 1] = { kind = "action", title = "Make your own voice (optional)",
            sub = "From a WAV recording: 10 to 20 seconds of one person speaking clearly. Only what the model "
                .. "needs is kept, not the recording.",
            button = "Choose recording", run = pickRecording }
    end
    return card
end

--- The engine's cards: Voice models, Baldr (the Turbo model, on every
-- computer with the engine), the GPU libraries (with a suitable NVIDIA
-- GPU, or always in Settings), then in Settings the voice for replies
-- (Baldr, the Windows voices, making your own) and the credits. A card
-- installing something has `progress = true`: its first row's sub is
-- voicemodels.progressText.
-- @param opts  { settings = true: Check, Repair, Remove, credits, and the off switch after a crash }
function voicemodels.cards(opts)
    opts = opts or {}
    local cards = { listenCard(opts), turboCard(opts) }
    local gpu = gpuCard(opts)
    if gpu then
        cards[#cards + 1] = gpu
    end
    local voices = opts.settings and voicesCard(opts) or nil
    if voices then
        cards[#cards + 1] = voices
    end
    if opts.settings then
        local credits = {}
        for _, c in ipairs(voicemodels.credits()) do
            credits[#credits + 1] = { kind = "info", title = c.title, sub = c.line }
        end
        credits[#credits + 1] = { kind = "info", title = "Speech engine",
            sub = "sherpa-onnx (Apache-2.0) and ONNX Runtime (MIT), in the voice folder beside GitGud; the GPU "
                .. "libraries add ONNX Runtime's CUDA provider. Without Bragi's voice model, replies use the voices "
                .. "Windows has." }
        cards[#cards + 1] = { heading = "Voice credits", rows = credits }
    end
    return cards
end

-- ---------------------------------------------------------------------
-- Words

--- The credits: the listening models, and Baldr's and the GPU libraries'
-- when they're in.
-- { { title, line, link }, ... }.
function voicemodels.credits()
    local out = {}
    local turbo = voicemodels.installed("turbo")
    local gpu = voicemodels.installed("gpu")
    for _, p in ipairs(voicemodels.PACKAGES) do
        if p.group == "listen" or (turbo and p.group == "turbo") then
            out[#out + 1] = {
                title = p.title,
                line = p.model .. ", by " .. p.credit .. ", under the " .. p.licence .. " license ("
                    .. LICENCE_LINKS[p.licence] .. ").",
                link = p.url,
            }
        end
    end
    if turbo then
        out[#out + 1] = { title = "Baldr",
            line = "Bragi's own voice, the project's own: its recording comes with the Bragi interface." }
    end
    if gpu then
        out[#out + 1] = { title = "NVIDIA libraries",
            line = "CUDA runtime, cuBLAS, cuFFT, cuRAND, NVRTC, nvJitLink, and cuDNN, from NVIDIA's packages, under "
                .. LICENCE_NAMES["NVIDIA-CUDA"] .. " (" .. LICENCE_LINKS["NVIDIA-CUDA"] .. ") and the "
                .. LICENCE_NAMES["NVIDIA-cuDNN"] .. " (" .. LICENCE_LINKS["NVIDIA-cuDNN"] .. "); their license "
                .. "files are in " .. gitgud.localDataPath(ROOT .. "/gpu") .. "." }
    end
    return out
end

local function callWords(call)
    return CALLS[call] or tostring(call or "a call")
end

--- Why voice stopped, from an engine error or gitgud.voiceEngine().
-- `e`: { code, message } (an error) or the engine table (faultCode, fault).
function voicemodels.faultText(e)
    local code = e.code or e.faultCode
    local detail = e.message or e.fault or ""
    if code == "engine-fault" or code == "engine-hung" then
        return "Voice stopped after an internal error in the speech engine"
            .. (code == "engine-hung" and " (it stopped answering)" or "")
            .. ". Restart GitGud to use voice again."
    elseif code == "engine-files" then
        return "The voice models need repairing: " .. detail .. ". Settings, Appearance and voice, Voice models."
    elseif code == "engine-missing" then
        if voicemodels.installed("gpu") then
            return "The GPU libraries didn't load: " .. detail .. ". Restart GitGud, or remove them in "
                .. "Settings, Appearance and voice."
        end
        return "The speech engine's files are missing or damaged: " .. detail .. ". Reinstall GitGud to fix them."
    elseif code == "engine-error" then
        return "Voice stopped: the speech engine failed several times in a row (" .. detail .. ")."
    end
    return "Voice stopped: " .. tostring(detail ~= "" and detail or code)
end

--- What to say about the app ending in the engine last time.
function voicemodels.crashText(crash)
    return "Last time, GitGud closed while voice was " .. callWords(crash.call) .. ", so voice is off for "
        .. "now. Press the mic button to turn it back on."
end

return voicemodels
