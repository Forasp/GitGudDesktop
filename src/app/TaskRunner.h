#pragma once

// -----------------------------------------------------------------------------
// TaskRunner — runs blocking work (clone/fetch/push/pull, big diffs) on worker
// threads and reports back over the EventBus (docs/PRINCIPLES.md: nothing
// blocks the UI thread).
//
// Contract per task `name`:
//   "<name>.started"  published when the worker picks the job up
//   "<name>.done"     published with the job's return string on success
//   "<name>.error"    published with the exception message on failure
//
// Because EventBus::publish only enqueues and the UI thread drains per frame,
// jobs may publish from their worker thread freely.
//
// libgit2 rule: worker threads must own their OWN Repository handle. Jobs
// should capture a repo *path* and Repository::open() it inside the job —
// never capture the UI thread's Repository&.
// -----------------------------------------------------------------------------

#include <atomic>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace gitgud::app
{

    class EventBus;

    class TaskRunner
    {
      public:
        explicit TaskRunner(EventBus& _Bus);
        ~TaskRunner(); // joins all workers; queued publishes stay in the bus

        TaskRunner(const TaskRunner&) = delete;
        TaskRunner& operator=(const TaskRunner&) = delete;

        // Start `job` on a new worker thread. The job's return value becomes the
        // "<name>.done" event detail.
        void Run(const std::string& _Name, std::function<std::string()> _Job);

        // True while any task is still running (drives UI busy indicators).
        bool Busy() const
        {
            return m_Active.load() > 0;
        }

      private:
        struct Worker
        {
            std::thread m_Thread;
            std::shared_ptr<std::atomic<bool>> m_Finished;
        };

        EventBus& m_Bus;
        std::atomic<int> m_Active{0};
        std::mutex m_WorkersMutex;
        std::vector<Worker> m_Workers;
    };

} // namespace gitgud::app
