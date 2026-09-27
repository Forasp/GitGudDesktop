#include "app/EventBus.h"

namespace gitgud::app
{

    void EventBus::Subscribe(const std::string& _Type, Handler _Handler)
    {
        m_Handlers[_Type].push_back(std::move(_Handler));
    }

    void EventBus::Publish(const AppEvent& _Event)
    {
        bool bwasEmpty = false;
        {
            std::lock_guard<std::mutex> lock(m_QueueMutex);
            bwasEmpty = m_Queue.empty();
            m_Queue.push_back(_Event);
        }
        if (bwasEmpty && m_Wake)
        {
            m_Wake();
        }
    }

    void EventBus::SetWakeCallback(std::function<void()> _Wake)
    {
        m_Wake = std::move(_Wake);
    }

    std::size_t EventBus::Drain()
    {
        std::size_t delivered = 0;
        // Loop so events published by handlers (e.g. Lua reacting to "fetch.done"
        // by publishing "status.changed") are also delivered this frame. The
        // queue is swapped out under the lock; handlers run without it so they
        // may publish freely.
        for (;;)
        {
            std::vector<AppEvent> batch;
            {
                std::lock_guard<std::mutex> lock(m_QueueMutex);
                if (m_Queue.empty())
                {
                    return delivered;
                }
                batch.swap(m_Queue);
            }
            delivered += batch.size();
            for (const auto& event : batch)
            {
                if (auto it = m_Handlers.find(event.m_Type); it != m_Handlers.end())
                {
                    for (const auto& h : it->second)
                    {
                        h(event);
                    }
                }
                if (auto it = m_Handlers.find("*"); it != m_Handlers.end())
                {
                    for (const auto& h : it->second)
                    {
                        h(event);
                    }
                }
            }
        }
    }

} // namespace gitgud::app
