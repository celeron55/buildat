// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "interface/worker_thread.h"
#include "interface/mutex.h"
#include "interface/semaphore.h"
#include "core/log.h"
#include <deque>
#ifdef _WIN32
	#include "ports/windows_compat.h"
#else
	#include <pthread.h>
	#include <semaphore.h>
#endif
#define MODULE "worker_thread"

namespace interface {
namespace worker_thread {

struct CThreadPool: public ThreadPool
{
	bool m_running = false;
	std::deque<up_<Task>> m_input_queue; // Push back, pop front
	std::deque<up_<Task>> m_output_queue; // Push back, pop front
	interface::Mutex m_mutex; // Protects each of the former variables
	interface::Semaphore m_tasks_sem; // Counts input tasks

	//std::deque<up_<Task>> m_pre_tasks; // Push back, pop front

	~CThreadPool()
	{
		request_stop();
		join();
	}

	struct Thread {
		bool stop_requested = true;
		bool running = false;
		interface::Mutex mutex; // Protects each of the former variables
		CThreadPool *pool = nullptr;
		pthread_t thread;
	};
	sv_<Thread> m_threads;

	static void *run_thread(void *arg)
	{
		log_d(MODULE, "Worker thread %p start", arg);
		Thread *thread = (Thread*)arg;
		for(;;){
			// Wait for a task
			thread->pool->m_tasks_sem.wait();
			up_<Task> current;
			{ // Grab the task from pool's input queue
				interface::MutexScope ms_pool(thread->pool->m_mutex);
				if(thread->pool->m_input_queue.empty()){
					// Can happen in special cases, eg. when stopping thread
					continue;
				}
				current = std::move(thread->pool->m_input_queue.front());
				thread->pool->m_input_queue.pop_front();
			}
			// Run the task's threaded part
			try {
				while(!current->thread());
			} catch(std::exception &e){
				log_w(MODULE, "Worker task failed: %s", e.what());
			}
			// Push the task to pool's output queue
			{
				interface::MutexScope ms_pool(thread->pool->m_mutex);
				thread->pool->m_output_queue.push_back(std::move(current));
			}
		}
		log_d(MODULE, "Worker thread %p exit", arg);
		interface::MutexScope ms(thread->mutex);
		thread->running = false;
		pthread_exit(NULL);
	}

	// Interface

	void add_task(up_<Task> task)
	{
		// TODO: Limit task->pre() execution time per frame
		while(!task->pre());
		interface::MutexScope ms(m_mutex);
		m_input_queue.push_back(std::move(task));
		m_tasks_sem.post();
	}

	void start(size_t num_threads)
	{
		interface::MutexScope ms(m_mutex);
		if(!m_threads.empty()){
			log_w(MODULE, "CThreadPool::start(): Already running");
			return;
		}
		m_threads.resize(num_threads);
		for(size_t i = 0; i < num_threads; i++){
			Thread &thread = m_threads[i];
			thread.pool = this;
			thread.stop_requested = false;
			if(pthread_create(&thread.thread, NULL, run_thread, (void*)&thread)){
				throw Exception("pthread_create() failed");
			}
			thread.running = true;
		}
	}

	void request_stop()
	{
		for(Thread &thread : m_threads){
			interface::MutexScope ms(thread.mutex);
			thread.stop_requested = true;
		}
	}

	void join()
	{
		for(Thread &thread : m_threads){
			interface::MutexScope ms(thread.mutex);
			if(!thread.stop_requested)
				log_w(MODULE, "Joining a thread that was not requested to stop");
			pthread_join(thread.thread, NULL);
		}
		m_threads.clear();
	}

	void run_post()
	{
		std::deque<up_<Task>> output_queue;
		{
			interface::MutexScope ms(m_mutex);
			output_queue.swap(m_output_queue);
		}
		// TODO: Limit task->post() execution time per frame
		for(auto &task : output_queue){
			while(!task->post());
		}
		// Done with tasks; discard them
	}
};

ThreadPool* createThreadPool()
{
	return new CThreadPool();
}

}
}
// vim: set noet ts=4 sw=4:
