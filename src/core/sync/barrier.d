/**
 * The barrier module provides a primitive for synchronizing the progress of
 * a group of threads.
 *
 * Copyright: Copyright Sean Kelly 2005 - 2009.
 * License:   $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Authors:   Sean Kelly
 * Source:    $(DRUNTIMESRC core/sync/_barrier.d)
 */

/*          Copyright Sean Kelly 2005 - 2009.
 * Distributed under the Boost Software License, Version 1.0.
 *    (See accompanying file LICENSE or copy at
 *          http://www.boost.org/LICENSE_1_0.txt)
 */
module core.sync.barrier;


public import core.sync.exception;
private import core.sync.condition;
private import core.sync.mutex;
private import core.atomic;

version( Win32 )
{
    private import core.sys.windows.windows;
}
else version( Posix )
{
    private import core.stdc.errno;
    private import core.sys.posix.pthread;
}


////////////////////////////////////////////////////////////////////////////////
// Barrier
//
// void wait();
////////////////////////////////////////////////////////////////////////////////


/**
 * This class represents a barrier across which threads may only travel in
 * groups of a specific size.
 */
shared class Barrier_
{
    ////////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////////


    /**
     * Initializes a barrier object which releases threads in groups of limit
     * in size.
     *
     * Params:
     *  limit = The number of waiting threads to release in unison.
     *
     * Throws:
     *  SyncException on error.
     */
    this( uint limit )
    in
    {
        assert( limit > 0 );
    }
    body
    {
        m_lock  = new Mutex;
        m_cond  = new Condition( m_lock );
        atomicStore!(MemoryOrder.rel)(m_group, 0);
        atomicStore!(MemoryOrder.rel)(m_limit, limit);
        atomicStore!(MemoryOrder.rel)(m_count, limit);
    }


    ////////////////////////////////////////////////////////////////////////////
    // General Actions
    ////////////////////////////////////////////////////////////////////////////


    /**
     * Wait for the pre-determined number of threads and then proceed.
     *
     * Throws:
     *  SyncException on error.
     */
    void wait()
    {
        synchronized( m_lock )
        {
            auto group = m_group.assumeLocal;

            if( --m_count.assumeLocal == 0 )
            {
                m_group.assumeLocal++;
                m_count.assumeLocal = m_limit.assumeLocal;
                m_cond.notifyAll();
            }
            while( group == m_group.assumeLocal )
                m_cond.wait();
        }
    }


private:
    Mutex       m_lock;
    Condition   m_cond;
    uint        m_group;
    uint        m_limit;
    uint        m_count;
}

alias Barrier = shared(Barrier_);


////////////////////////////////////////////////////////////////////////////////
// Unit Tests
////////////////////////////////////////////////////////////////////////////////


version( unittest )
{
    private import core.thread;


    unittest
    {
        enum int   numThreads = 10;
        auto       barrier    = new Barrier( numThreads );
        auto       synInfo    = new shared Object;
        shared int numReady   = 0;
        shared int numPassed  = 0;

        void threadFn()
        {
            synchronized( synInfo )
            {
                ++numReady.assumeLocal;
            }
            barrier.wait();
            synchronized( synInfo )
            {
                ++numPassed.assumeLocal;
            }
        }

        auto group = new ThreadGroup;

        for( int i = 0; i < numThreads; ++i )
        {
            group.create( &threadFn );
        }
        group.joinAll();
        assert( numReady.assumeLocal == numThreads && numPassed.assumeLocal == numThreads );
    }
}
