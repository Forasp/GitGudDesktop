#pragma once

// -----------------------------------------------------------------------------
// Audio: microphone capture and speaker playback for voice, mono 16-bit PCM.
//
// Windows: capture through the Voice Capture DSP (the system's echo
// cancellation: it opens the microphone and a loopback of the speaker and
// subtracts what's played), falling back to plain WASAPI capture where the
// DSP can't run; playback through WASAPI shared mode. Both convert to the
// app's format in the audio engine. Other platforms: Start() fails.
//
// The voice session only sees these interfaces, so tests feed it synthetic
// audio and never touch a device.
//
// Devices: the system's default microphone and speaker (the console role,
// where other apps play and record), unless SetAudioDevices picked others
// (the next Start() uses them; one that's gone falls back to the default).
// Not the communications defaults: voice takes commands, it isn't a call.
// Playback and the echo canceller's reference are the same speaker, so
// what the canceller subtracts is what Bragi played. Every stream opts out
// of turning other apps' audio down (Windows' "ducking" during calls).
// The DSP gives no output while its speaker has no stream running, so
// while it runs a silent stream of our own keeps that speaker going.
// -----------------------------------------------------------------------------

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace gitgud::platform
{

    class IAudioCapture
    {
      public:
        // Runs on the capture thread with the next samples.
        using OnSamples = std::function<void(const int16_t* _pSamples, std::size_t _nCount)>;

        virtual ~IAudioCapture() = default;

        // Open the default microphone at `_iSampleRate` (the DSP gives 16 kHz
        // only) and start delivering samples. False with `_Error` if it
        // can't.
        virtual bool Start(int _iSampleRate, OnSamples _OnSamples, std::string& _Error) = 0;
        virtual void Stop() = 0;
        // What is capturing, for people ("Microphone (echo cancelled)").
        virtual std::string Description() const = 0;

        // Why the capture stopped on its own, if it did ("" otherwise).
        virtual std::string LastError() const
        {
            return {};
        }

        // Which devices it opened and whether it kept other apps' audio
        // from being turned down, for the log ("mic: Webcam (default);
        // echo reference: Speakers (default); ducking opt-out: ok"); "" before
        // it has started or when it can't say.
        virtual std::string Route() const
        {
            return {};
        }
    };

    class IAudioPlayback
    {
      public:
        virtual ~IAudioPlayback() = default;

        // Open the default speaker at `_iSampleRate`; it plays silence until
        // samples are queued.
        virtual bool Start(int _iSampleRate, std::string& _Error) = 0;
        virtual void Stop() = 0;
        virtual int SampleRate() const = 0;

        // Queue samples at SampleRate(); Flush drops what hasn't played.
        virtual void Enqueue(const int16_t* _pSamples, std::size_t _nCount) = 0;
        virtual void Flush() = 0;
        virtual std::size_t Queued() const = 0;
        // The speaker it plays on, once started ("" when unknown).
        virtual std::string Description() const
        {
            return {};
        }
    };

    // The echo-cancelled microphone, or plain capture where the DSP fails to
    // start or stops giving audio (Description() says which). The DSP is
    // tried three ways before giving up on it (MakeFallbackCapture): the
    // devices by index with other apps' audio kept up, the same without
    // that opt-out, and the system's default devices; Route() says which
    // ran and why the ones before it didn't.
    std::unique_ptr<IAudioCapture> MakeVoiceCapture();
    std::unique_ptr<IAudioPlayback> MakePlayback();
    // Plain capture from the chosen microphone (a level meter's).
    std::unique_ptr<IAudioCapture> MakePlainCapture();
    // The first of `_Stages` that starts, swapped for the next when it gives
    // no samples for `_Stall`; the last runs unwatched (MakeVoiceCapture's
    // echo cancellers, then plain capture; tests pass fakes). Once the last
    // runs, Description() says why the one before it failed; Route() adds
    // every failed stage and why ("tried before: ...").
    std::unique_ptr<IAudioCapture> MakeFallbackCapture(
        std::vector<std::unique_ptr<IAudioCapture>> _Stages, std::chrono::milliseconds _Stall);
    // The same with two stages.
    std::unique_ptr<IAudioCapture> MakeFallbackCapture(std::unique_ptr<IAudioCapture> _pFirst,
        std::unique_ptr<IAudioCapture> _pSecond, std::chrono::milliseconds _Stall);

    struct AudioDevice
    {
        std::string m_Id;   // the system's endpoint id
        std::string m_Name; // for people ("Headset Microphone (USB)")
        bool m_bDefault = false;
    };

    // The microphones (`_bCapture`) or speakers plugged in and enabled, in
    // the system's order; m_bDefault marks the default one voice opens.
    // Empty where devices can't be listed.
    std::vector<AudioDevice> ListAudioDevices(bool _bCapture);

    // The devices voice uses from the next Start(); "" is the default.
    void SetAudioDevices(const std::string& _CaptureId, const std::string& _RenderId);

    // How the echo canceller runs, from its next Start(): how long an echo
    // it follows (128, 256, 512 or 1024 ms), its noise suppression, and
    // center clipping (it mutes what's left quiet after the echo is taken
    // out, soft words with it).
    //
    // `m_iDelayMs` above 0 is how late the speaker's sound reaches the
    // microphone, past what the system knows about (a receiver, a
    // soundbar, a long digital output: about 250 ms on one setup, where the
    // system's canceller took out almost nothing). Voice then lines the
    // speaker up itself: the canceller gets the microphone and a loopback
    // of the speaker that much earlier (filter mode), with center clipping
    // on. 0: the canceller finds the speaker by itself, as before.
    struct EchoOptions
    {
        int m_iEchoLengthMs = 512;
        bool m_bNoiseSuppression = true;
        bool m_bCenterClip = false;
        int m_iDelayMs = 0;
        // Its residual echo suppression after the canceller: how many passes,
        // 0 (off) to 2. On, it took a soundbar's echo from 6 to 22 dB below
        // what the microphone hears, close to the room's own noise; without
        // it the canceller alone leaves Bragi loud enough to pass for speech.
        int m_iSuppression = 1;
    };

    void SetEchoOptions(const EchoOptions& _Options);
    EchoOptions CurrentEchoOptions();

    // The echo canceller in filter mode, on samples instead of devices:
    // `_Mic` (what the microphone heard) with `_Reference` (what played,
    // lined up with it), both 16 kHz mono, sample for sample. `_Out` gets
    // the cancelled microphone. False with `_Error` where it can't run
    // (not Windows, or the DSP refused).
    bool CancelEcho(const std::vector<int16_t>& _Mic, const std::vector<int16_t>& _Reference,
        const EchoOptions& _Options, std::vector<int16_t>& _Out, std::string& _Error);

    // Samples stamped with the system clock (100 ns units), as a capture
    // stream hands them over: each packet's first sample has a time, the
    // rest follow at the rate. Lines a speaker's loopback up with the
    // microphone. Indexes count every sample pushed; TrimBefore lets the
    // old ones go.
    class EchoTimeline
    {
      public:
        explicit EchoTimeline(int _iRate = 16000) : m_iRate(_iRate)
        {
        }

        // `_iTime` < 0: no time for this packet; it follows the last.
        void Push(const int16_t* _pSamples, std::size_t _nCount, int64_t _iTime);
        // The time of sample `_iIndex`, from the nearest stamped packet at
        // or before it (the first one's, for an index before it).
        int64_t TimeOf(int64_t _iIndex) const;
        // The index of the sample heard at `_iTime` (may be outside what's
        // kept).
        int64_t IndexAt(int64_t _iTime) const;
        // `_nCount` samples from `_iFrom` into `_Out` (replaced): zeros for
        // what's gone or hasn't come yet.
        void Copy(int64_t _iFrom, std::size_t _nCount, std::vector<int16_t>& _Out) const;

        int64_t Begin() const
        {
            return m_iBegin;
        }

        int64_t End() const
        {
            return m_iBegin + static_cast<int64_t>(m_Samples.size());
        }

        bool Stamped() const
        {
            return !m_Anchors.empty();
        }

        void TrimBefore(int64_t _iIndex);

      private:
        struct Anchor
        {
            int64_t m_iIndex;
            int64_t m_iTime;
        };

        int m_iRate;
        int64_t m_iBegin = 0;
        std::vector<int16_t> m_Samples;
        std::vector<Anchor> m_Anchors;
    };

    // How far `_Mic` trails `_Reference`, in samples (0 to `_iMaxLag`):
    // where the two match best. `_pCorrelation` (optional) says how well,
    // 0 to 1.
    int EchoLag(const std::vector<int16_t>& _Reference, const std::vector<int16_t>& _Mic,
        int _iMaxLag, double* _pCorrelation);

    // The echo test's sound at `_iRate`: four short chirps at uneven gaps
    // (beeps that sweep up, so each matches its echo in one place only).
    std::vector<int16_t> EchoTestSignal(int _iRate);

    // What MeasureEcho found.
    struct EchoMeasurement
    {
        bool m_bOk = false;    // it ran (else m_Error says why)
        bool m_bHeard = false; // the microphone heard the chirps clearly
        double m_fDelayMs = 0; // how late the speaker reaches the microphone
        double m_fCorrelation = 0;
        double m_fEchoDb = 0;  // the chirps in the microphone (dBFS)
        double m_fFloorDb = 0; // the room before them (dBFS)
        std::string m_Error;
        std::string m_Route; // the devices it used, for the log
    };

    // Play `_Signal` (16 kHz mono; empty: EchoTestSignal) on the speaker
    // voice uses while recording the microphone and the speaker's
    // loopback, and measure how late the microphone hears it: the delay
    // for EchoOptions. Blocks for the signal's length and two seconds more.
    // Windows only. (Some microphones filter out tones: speech gets
    // through them.)
    EchoMeasurement MeasureEcho(const std::vector<int16_t>& _Signal = {});
    void ChosenAudioDevices(std::string& _CaptureId, std::string& _RenderId);

    // The endpoint voice opens: `_Chosen` while it's among `_Active` (the
    // endpoints plugged in), else `_Default` while that is, else "".
    std::string PickAudioEndpoint(const std::string& _Chosen, const std::string& _Default,
        const std::vector<std::string>& _Active);

    // The Voice Capture DSP's device indexes (MFPKEY_WMAAECMA_DEVICE_INDEXES)
    // for two endpoints, found by id: the speaker's place in `_Renders` in
    // the high 16 bits, the microphone's in `_Captures` in the low. The lists
    // are the active endpoints in the system's order, the collection the
    // DSP counts in. False when either isn't listed.
    bool EchoDeviceIndexes(const std::string& _CaptureId, const std::vector<std::string>& _Captures,
        const std::string& _RenderId, const std::vector<std::string>& _Renders, int32_t& _iPacked);

} // namespace gitgud::platform
