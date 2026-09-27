#include "app/TaskRunner.h"

#include <exception>
#include <utility>

#include "app/EventBus.h"

namespace gitgud::app
{

    TaskRunner::TaskRunner(EventBus& _Bus) : m_Bus(_Bus)
    {
    }

    TaskRunner::~TaskRunner()
    {
        std::lock_guard<std::mutex> lock(m_WorkersMutex);
        for (auto& w : m_Workers)
        {
            if (w.m_Thread.joinable())
            {
                w.m_Thread.join();
            }
        }
    }

    void TaskRunner::Run(const std::string& _Name, std::function<std::string()> _Job)
    {
        auto finished = std::make_shared<std::atomic<bool>>(false);
        ++m_Active;

        std::thread worker(
            [this, _Name, job = std::move(_Job), finished]()
            {
                m_Bus.Publish({_Name + ".started", _Name});
                try
                {
                    const std::string result = job();
                    m_Bus.Publish({_Name + ".done", result});
                }
                catch (const std::exception& e)
                {
                    m_Bus.Publish({_Name + ".error", e.what()});
                }
                catch (...)
                {
                    m_Bus.Publish({_Name + ".error", "unknown error"});
                }
                --m_Active;
                finished->store(true);
            });

        // Reap workers that already finished so the vector doesn't grow without
        // bound over a long session, then keep the new one.
        std::lock_guard<std::mutex> lock(m_WorkersMutex);
        for (auto it = m_Workers.begin(); it != m_Workers.end();)
        {
            if (it->m_Finished->load())
            {
                if (it->m_Thread.joinable())
                {
                    it->m_Thread.join();
                }
                it = m_Workers.erase(it);
            }
            else
            {
                ++it;
            }
        }
        m_Workers.push_back(Worker{std::move(worker), std::move(finished)});
    }

} // namespace gitgud::app
