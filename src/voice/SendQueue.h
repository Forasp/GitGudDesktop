#pragma once

// -----------------------------------------------------------------------------
// SendQueue: what one voice link (voice/Link.h) sends, in order, on a thread
// of its own.
//
// A link's send may block while the other end is busy: an engine that stops
// reading holds each send up. Callers only queue, so the microphone and the
// session's events never wait on the link.
//
// Binary messages (mic frames) are capped: past the cap the oldest waiting
// frame is dropped, so what reaches the engine once it reads again is the
// latest audio, in order. Drops are counted with the frames' times
// (TakeDrops) for the log. Text (control messages) is never dropped.
// -----------------------------------------------------------------------------

#include <chrono>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <functional>
#include <limits>
#include <mutex>
#include <string>
#include <thread>

namespace gitgud::voice
{

    class SendQueue
    {
      public:
        // Sends one message; false if the link failed (sending stops).
        using Send = std::function<bool(bool _bBinary, const std::string& _Data)>;

        // Frames dropped since the last TakeDrops.
        struct Drops
        {
            std::size_t m_nCount = 0;
            int64_t m_iFirstMs = 0; // the first dropped frame's time
            int64_t m_iLastMs = 0;  // the last one's
        };

        explicit SendQueue(std::size_t _nMaxBinary = (std::numeric_limits<std::size_t>::max)());
        ~SendQueue(); // Stop()

        SendQueue(const SendQueue&) = delete;
        SendQueue& operator=(const SendQueue&) = delete;

        // Empty the queue and reset the counts (while stopped).
        void Clear();
        // Send through `_Send` on the queue's thread, oldest first (what was
        // queued before Start goes first).
        void Start(Send _Send);
        // End the thread once the send in progress returns. What is still
        // queued stays queued.
        void Stop();

        void PushText(std::string _Text);
        // A mic frame and its time (ms since the first sample).
        void PushBinary(std::string _Data, int64_t _iMs);

        // Wait until everything queued is sent (or sending failed), up to
        // `_Timeout`. True if nothing is left.
        bool Drain(std::chrono::milliseconds _Timeout);

        Drops TakeDrops();
        std::size_t DroppedTotal() const;
        std::size_t QueuedBinary() const;
        // How long the send in progress has been waiting (0 when none).
        std::chrono::milliseconds Sending() const;
        // A send failed: sending stopped.
        bool Failed() const;

      private:
        struct Outgoing
        {
            bool m_bBinary = false;
            std::string m_Data;
            int64_t m_iMs = 0;
        };

        void Loop();

        const std::size_t m_nMaxBinary;
        Send m_Send;
        std::thread m_Thread;
        mutable std::mutex m_Mutex;
        std::condition_variable m_Wake; // something queued, or stop
        std::condition_variable m_Idle; // a send finished
        std::deque<Outgoing> m_Queue;
        std::size_t m_nQueuedBinary = 0;
        bool m_bStop = false;
        bool m_bSending = false;
        bool m_bFailed = false;
        std::chrono::steady_clock::time_point m_SendStart;
        Drops m_Drops;
        std::size_t m_nDroppedTotal = 0;
    };

} // namespace gitgud::voice
