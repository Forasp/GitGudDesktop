#pragma once

// -----------------------------------------------------------------------------
// EventBus — the one-way channel from the core to the UI.
//
// Worker threads (fetch/push/clone, see TaskRunner) and controllers publish
// plain-data events; subscribers (the UI layer) react and re-render from
// state. Keeping this decoupled is what lets long-running Git operations run
// off the UI thread.
//
// Threading model: publish() may be called from ANY thread — it only
// enqueues. Nothing is dispatched until the UI thread calls drain() once per
// frame, so handlers always run on the UI thread and never need locks.
// subscribe() is main-thread-only (wire everything up during startup).
// -----------------------------------------------------------------------------

#include <functional>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

namespace gitgud::app
{

    // A coarse event kind; refine into a proper enum/variant as the app grows.
    struct AppEvent
    {
        std::string m_Type;   // e.g. "status.changed", "push.error", "fetch.done"
        std::string m_Detail; // human-readable payload
    };

    class EventBus
    {
      public:
        using Handler = std::function<void(const AppEvent&)>;

        // Subscribe to one event type, or to "*" to receive every event (used to
        // forward the whole stream into Lua).
        void Subscribe(const std::string& _Type, Handler _Handler);

        // Enqueue an event. Safe from any thread. Delivery happens in drain().
        void Publish(const AppEvent& _Event);

        // Called (from the publishing thread) whenever an event lands in an
        // empty queue, so an idle UI thread blocked waiting for input can wake
        // up and drain. Set once at startup.
        void SetWakeCallback(std::function<void()> _Wake);

        // Dispatch everything queued since the last drain. Call once per frame
        // from the UI thread. Events published BY handlers during a drain are
        // delivered in the same drain (queue is re-checked), so chains settle
        // within one frame. Returns how many events were delivered.
        std::size_t Drain();

      private:
        std::unordered_map<std::string, std::vector<Handler>> m_Handlers;
        std::mutex m_QueueMutex;
        std::vector<AppEvent> m_Queue;
        std::function<void()> m_Wake;
    };

} // namespace gitgud::app
