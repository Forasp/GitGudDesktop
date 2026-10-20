#include "voice/SendQueue.h"

#include <utility>

namespace gitgud::voice
{

    SendQueue::SendQueue(std::size_t _nMaxBinary) : m_nMaxBinary(_nMaxBinary)
    {
    }

    SendQueue::~SendQueue()
    {
        Stop();
    }

    void SendQueue::Clear()
    {
        std::lock_guard<std::mutex> lock(m_Mutex);
        m_Queue.clear();
        m_nQueuedBinary = 0;
        m_bFailed = false;
        m_Drops = Drops();
        m_nDroppedTotal = 0;
    }

    void SendQueue::Start(Send _Send)
    {
        Stop();
        {
            std::lock_guard<std::mutex> lock(m_Mutex);
            m_bStop = false;
            m_bFailed = false;
        }
        m_Send = std::move(_Send);
        m_Thread = std::thread([this]() { Loop(); });
    }

    void SendQueue::Stop()
    {
        {
            std::lock_guard<std::mutex> lock(m_Mutex);
            m_bStop = true;
        }
        m_Wake.notify_all();
        if (m_Thread.joinable())
        {
            m_Thread.join();
        }
    }

    void SendQueue::PushText(std::string _Text)
    {
        {
            std::lock_guard<std::mutex> lock(m_Mutex);
            m_Queue.push_back({false, std::move(_Text), 0});
        }
        m_Wake.notify_all();
    }

    void SendQueue::PushBinary(std::string _Data, int64_t _iMs)
    {
        {
            std::lock_guard<std::mutex> lock(m_Mutex);
            m_Queue.push_back({true, std::move(_Data), _iMs});
            ++m_nQueuedBinary;
            // Over the cap: the oldest frame goes. Frames are queued in
            // time order, so it is the first binary one.
            while (m_nQueuedBinary > m_nMaxBinary)
            {
                for (auto it = m_Queue.begin(); it != m_Queue.end(); ++it)
                {
                    if (it->m_bBinary)
                    {
                        if (m_Drops.m_nCount == 0)
                        {
                            m_Drops.m_iFirstMs = it->m_iMs;
                        }
                        m_Drops.m_iLastMs = it->m_iMs;
                        ++m_Drops.m_nCount;
                        ++m_nDroppedTotal;
                        m_Queue.erase(it);
                        --m_nQueuedBinary;
                        break;
                    }
                }
            }
        }
        m_Wake.notify_all();
    }

    bool SendQueue::Drain(std::chrono::milliseconds _Timeout)
    {
        std::unique_lock<std::mutex> lock(m_Mutex);
        m_Idle.wait_for(lock, _Timeout,
            [this]() { return m_bFailed || (m_Queue.empty() && !m_bSending); });
        return m_Queue.empty() && !m_bSending;
    }

    SendQueue::Drops SendQueue::TakeDrops()
    {
        std::lock_guard<std::mutex> lock(m_Mutex);
        return std::exchange(m_Drops, Drops());
    }

    std::size_t SendQueue::DroppedTotal() const
    {
        std::lock_guard<std::mutex> lock(m_Mutex);
        return m_nDroppedTotal;
    }

    std::size_t SendQueue::QueuedBinary() const
    {
        std::lock_guard<std::mutex> lock(m_Mutex);
        return m_nQueuedBinary;
    }

    std::chrono::milliseconds SendQueue::Sending() const
    {
        std::lock_guard<std::mutex> lock(m_Mutex);
        if (!m_bSending)
        {
            return std::chrono::milliseconds(0);
        }
        return std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - m_SendStart);
    }

    bool SendQueue::Failed() const
    {
        std::lock_guard<std::mutex> lock(m_Mutex);
        return m_bFailed;
    }

    void SendQueue::Loop()
    {
        for (;;)
        {
            Outgoing next;
            {
                std::unique_lock<std::mutex> lock(m_Mutex);
                m_Wake.wait(lock, [this]() { return m_bStop || !m_Queue.empty(); });
                if (m_bStop)
                {
                    return;
                }
                next = std::move(m_Queue.front());
                m_Queue.pop_front();
                if (next.m_bBinary)
                {
                    --m_nQueuedBinary;
                }
                m_bSending = true;
                m_SendStart = std::chrono::steady_clock::now();
            }
            // No lock held: callers keep queueing (and dropping) meanwhile.
            const bool bsent = m_Send(next.m_bBinary, next.m_Data);
            {
                std::lock_guard<std::mutex> lock(m_Mutex);
                m_bSending = false;
                m_bFailed = !bsent;
            }
            m_Idle.notify_all();
            if (!bsent)
            {
                return; // the link is going: its close says why
            }
        }
    }

} // namespace gitgud::voice
