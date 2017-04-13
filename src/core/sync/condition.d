/**
 * The condition module provides a primitive for synchronized condition
 * checking.
 *
 * Copyright: Copyright Sean Kelly 2005 - 2009.
 * License:   $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Authors:   Sean Kelly
 * Source:    $(DRUNTIMESRC core/sync/_condition.d)
 */

/*          Copyright Sean Kelly 2005 - 2009.
 * Distributed under the Boost Software License, Version 1.0.
 *    (See accompanying file LICENSE or copy at
 *          http://www.boost.org/LICENSE_1_0.txt)
 */
module core.sync.condition;


public import core.sync.exception;
public import core.sync.mutex;
public import core.time;

version( Windows )
{
    private import core.sync.semaphore;
    private import core.sys.windows.windows;
}
else version( Posix )
{
    private import core.sync.config;
    private import core.stdc.errno;
    private import core.sys.posix.pthread;
    private import core.sys.posix.time;
}
else
{
    static assert(false, "Platform not supported");
}

import core.atomic;

////////////////////////////////////////////////////////////////////////////////
// Condition
//
// void wait();
// void notify();
// void notifyAll();
////////////////////////////////////////////////////////////////////////////////


/**
 * This class represents a condition variable as conceived by C.A.R. Hoare.  As
 * per Mesa type monitors however, "signal" has been replaced with "notify" to
 * indicate that control is not transferred to the waiter when a notification
 * is sent.
 */
shared class Condition_
{
    ////////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////////

    /**
     * Initializes a condition object which is associated with the supplied
     * mutex object.
     *
     * Params:
     *  m = The mutex with which this condition will be associated.
     *
     * Throws:
     *  SyncError on error.
     */
    this( Mutex m ) shared nothrow @safe
    {
        version( Windows )
        {
            m_blockLock = CreateSemaphoreA( null, 1, 1, null );
            if( m_blockLock == m_blockLock.init )
                throw new SyncError( "Unable to initialize condition" );
            scope(failure) CloseHandle( m_blockLock );

            m_blockQueue = CreateSemaphoreA( null, 0, int.max, null );
            if( m_blockQueue == m_blockQueue.init )
                throw new SyncError( "Unable to initialize condition" );
            scope(failure) CloseHandle( m_blockQueue );

            () @trusted {
                InitializeCriticalSection( cast(CRITICAL_SECTION*) &m_unblockLock );
            }();
            m_assocMutex = m;
        }
        else version( Posix )
        {
            m_assocMutex = m;
            int rc = () @trusted {
                return pthread_cond_init( cast(pthread_cond_t*)&m_hndl, null );
            }();
            if( rc )
                throw new SyncError( "Unable to initialize condition" );
        }
    }


    ~this() shared
    {
        version( Windows )
        {
            BOOL rc = CloseHandle( cast(HANDLE) m_blockLock );
            assert( rc, "Unable to destroy condition" );
            rc = CloseHandle( cast(HANDLE) m_blockQueue );
            assert( rc, "Unable to destroy condition" );
            DeleteCriticalSection( cast(CRITICAL_SECTION*) &m_unblockLock );
        }
        else version( Posix )
        {
            int rc = pthread_cond_destroy( cast(pthread_cond_t*)&m_hndl );
            assert( !rc, "Unable to destroy condition" );
        }
    }


    ////////////////////////////////////////////////////////////////////////////
    // General Properties
    ////////////////////////////////////////////////////////////////////////////


    /**
     * Gets the mutex associated with this condition.
     *
     * Returns:
     *  The mutex associated with this condition.
     */
    @property Mutex mutex()
    {
        return m_assocMutex;
    }

    // undocumented function for internal use
    final @property Mutex mutex_nothrow() pure nothrow @safe @nogc
    {
        return m_assocMutex;
    }


    ////////////////////////////////////////////////////////////////////////////
    // General Actions
    ////////////////////////////////////////////////////////////////////////////


    /**
     * Wait until notified.
     *
     * Throws:
     *  SyncError on error.
     */
    void wait()
    {
        version( Windows )
        {
            timedWait( INFINITE );
        }
        else version( Posix )
        {
            int rc = pthread_cond_wait( cast(pthread_cond_t*)&m_hndl, m_assocMutex.handleAddr() );
            if( rc )
                throw new SyncError( "Unable to wait for condition" );
        }
    }


    /**
     * Suspends the calling thread until a notification occurs or until the
     * supplied time period has elapsed.
     *
     * Params:
     *  val = The time to wait.
     *
     * In:
     *  val must be non-negative.
     *
     * Throws:
     *  SyncError on error.
     *
     * Returns:
     *  true if notified before the timeout and false if not.
     */
    bool wait( Duration val )
    in
    {
        assert( !val.isNegative );
    }
    body
    {
        version( Windows )
        {
            auto maxWaitMillis = dur!("msecs")( uint.max - 1 );

            while( val > maxWaitMillis )
            {
                if( timedWait( cast(uint)
                               maxWaitMillis.total!"msecs" ) )
                    return true;
                val -= maxWaitMillis;
            }
            return timedWait( cast(uint) val.total!"msecs" );
        }
        else version( Posix )
        {
            timespec t = void;
            mktspec( t, val );

            int rc = pthread_cond_timedwait( cast(pthread_cond_t*)&m_hndl,
                                             m_assocMutex.handleAddr(),
                                             &t );
            if( !rc )
                return true;
            if( rc == ETIMEDOUT )
                return false;
            throw new SyncError( "Unable to wait for condition" );
        }
    }


    /**
     * Notifies one waiter.
     *
     * Throws:
     *  SyncError on error.
     */
    void notify()
    {
        version( Windows )
        {
            notify( false );
        }
        else version( Posix )
        {
            int rc = pthread_cond_signal( cast(pthread_cond_t*)&m_hndl );
            if( rc )
                throw new SyncError( "Unable to notify condition" );
        }
    }


    /**
     * Notifies all waiters.
     *
     * Throws:
     *  SyncError on error.
     */
    void notifyAll()
    {
        version( Windows )
        {
            notify( true );
        }
        else version( Posix )
        {
            int rc = pthread_cond_broadcast( cast(pthread_cond_t*)&m_hndl );
            if( rc )
                throw new SyncError( "Unable to notify condition" );
        }
    }


private:
    version( Windows )
    {
        bool timedWait( DWORD timeout )
        {
            int   numSignalsLeft;
            int   numWaitersGone;
            DWORD rc;

            rc = WaitForSingleObject( cast(HANDLE) m_blockLock, INFINITE );
            assert( rc == WAIT_OBJECT_0 );

            atomicOp!"+="( m_numWaitersBlocked, 1 );

            rc = ReleaseSemaphore( cast(HANDLE) m_blockLock, 1, null );
            assert( rc );

            m_assocMutex.unlock();
            scope(failure) m_assocMutex.lock();

            rc = WaitForSingleObject( cast(HANDLE) m_blockQueue, timeout );
            assert( rc == WAIT_OBJECT_0 || rc == WAIT_TIMEOUT );
            bool timedOut = (rc == WAIT_TIMEOUT);

            EnterCriticalSection( cast(CRITICAL_SECTION*) &m_unblockLock );
            scope(failure) LeaveCriticalSection( cast(CRITICAL_SECTION*) &m_unblockLock );

            if( (numSignalsLeft = m_numWaitersToUnblock.assumeUnshared) != 0 )
            {
                if ( timedOut )
                {
                    // timeout (or canceled)
                    if( atomicLoad!( MemoryOrder.acq )( m_numWaitersBlocked ) != 0 )
                    {
                        atomicOp!"-="( m_numWaitersBlocked, 1 );
                        // do not unblock next waiter below (already unblocked)
                        numSignalsLeft = 0;
                    }
                    else
                    {
                        // spurious wakeup pending!!
                        m_numWaitersGone.assumeUnshared = 1;
                    }
                }
                if( --m_numWaitersToUnblock.assumeUnshared == 0 )
                {
                    if( atomicLoad!( MemoryOrder.acq )( m_numWaitersBlocked ) != 0 )
                    {
                        // open the gate
                        rc = ReleaseSemaphore( cast(HANDLE) m_blockLock, 1, null );
                        assert( rc );
                        // do not open the gate below again
                        numSignalsLeft = 0;
                    }
                    else if( (numWaitersGone = m_numWaitersGone.assumeUnshared) != 0 )
                    {
                        m_numWaitersGone.assumeUnshared = 0;
                    }
                }
            }
            else if( ++m_numWaitersGone.assumeUnshared == int.max / 2 )
            {
                // timeout/canceled or spurious event :-)
                rc = WaitForSingleObject( cast(HANDLE) m_blockLock, INFINITE );
                assert( rc == WAIT_OBJECT_0 );
                // something is going on here - test of timeouts?
                atomicOp!"-="( m_numWaitersBlocked, m_numWaitersGone.assumeUnshared );
                rc = ReleaseSemaphore( cast(HANDLE) m_blockLock, 1, null );
                assert( rc == WAIT_OBJECT_0 );
                m_numWaitersGone.assumeUnshared = 0;
            }

            LeaveCriticalSection( cast(CRITICAL_SECTION*) &m_unblockLock );

            if( numSignalsLeft == 1 )
            {
                // better now than spurious later (same as ResetEvent)
                for( ; numWaitersGone > 0; --numWaitersGone )
                {
                    rc = WaitForSingleObject( cast(HANDLE) m_blockQueue, INFINITE );
                    assert( rc == WAIT_OBJECT_0 );
                }
                // open the gate
                rc = ReleaseSemaphore( cast(HANDLE) m_blockLock, 1, null );
                assert( rc );
            }
            else if( numSignalsLeft != 0 )
            {
                // unblock next waiter
                rc = ReleaseSemaphore( cast(HANDLE) m_blockQueue, 1, null );
                assert( rc );
            }
            m_assocMutex.lock();
            return !timedOut;
        }


        void notify( bool all )
        {
            DWORD rc;

            EnterCriticalSection( cast(CRITICAL_SECTION*) &m_unblockLock );
            scope(failure) LeaveCriticalSection( cast(CRITICAL_SECTION*) &m_unblockLock );

            if( m_numWaitersToUnblock.assumeUnshared != 0 )
            {
                if( atomicLoad!( MemoryOrder.acq )( m_numWaitersBlocked ) == 0 )
                {
                    LeaveCriticalSection( cast(CRITICAL_SECTION*)&m_unblockLock );
                    return;
                }
                if( all )
                {
                    m_numWaitersToUnblock.assumeUnshared += atomicLoad!( MemoryOrder.acq )( m_numWaitersBlocked );
                    atomicStore!( MemoryOrder.rel )( m_numWaitersBlocked, 0 );
                }
                else
                {
                    ++m_numWaitersToUnblock.assumeUnshared;
                    atomicOp!"-="( m_numWaitersBlocked, 1 );
                }
                LeaveCriticalSection( cast(CRITICAL_SECTION*) &m_unblockLock );
            }
            else if( atomicLoad!( MemoryOrder.acq )( m_numWaitersBlocked ) > m_numWaitersGone.assumeUnshared )
            {
                rc = WaitForSingleObject( cast(HANDLE) m_blockLock, INFINITE );
                assert( rc == WAIT_OBJECT_0 );
                if( 0 != m_numWaitersGone.assumeUnshared )
                {
                    atomicOp!"-="( m_numWaitersBlocked, m_numWaitersGone.assumeUnshared );
                    m_numWaitersGone.assumeUnshared = 0;
                }
                if( all )
                {
                    m_numWaitersToUnblock.assumeUnshared = atomicLoad!( MemoryOrder.acq )( m_numWaitersBlocked );
                    atomicStore!( MemoryOrder.rel )( m_numWaitersBlocked, 0 );
                }
                else
                {
                    m_numWaitersToUnblock.assumeUnshared = 1;
                    atomicOp!"-="( m_numWaitersBlocked, 1 );
                }
                LeaveCriticalSection( cast(CRITICAL_SECTION*)&m_unblockLock );
                rc = ReleaseSemaphore( cast(HANDLE) m_blockQueue, 1, null );
                assert( rc );
            }
            else
            {
                LeaveCriticalSection( cast(CRITICAL_SECTION*) &m_unblockLock );
            }
        }


        // NOTE: This implementation uses Algorithm 8c as described here:
        //       http://groups.google.com/group/comp.programming.threads/
        //              browse_frm/thread/1692bdec8040ba40/e7a5f9d40e86503a
        HANDLE              m_blockLock;    // auto-reset event (now semaphore)
        HANDLE              m_blockQueue;   // auto-reset event (now semaphore)
        Mutex               m_assocMutex;   // external mutex/CS
        CRITICAL_SECTION    m_unblockLock;  // internal mutex/CS
        int                 m_numWaitersGone        = 0;
        int                 m_numWaitersBlocked     = 0;
        int                 m_numWaitersToUnblock   = 0;
    }
    else version( Posix )
    {
        Mutex               m_assocMutex;
        pthread_cond_t      m_hndl;
    }
}

alias Condition = shared(Condition_);

////////////////////////////////////////////////////////////////////////////////
// Unit Tests
////////////////////////////////////////////////////////////////////////////////


version( unittest )
{
    private import core.thread;
    private import core.sync.mutex;
    private import core.sync.semaphore;


    void testNotify()
    {
        auto        mutex      = new Mutex;
        auto        condReady  = new Condition( mutex );
        auto        semDone    = new Semaphore;
        auto        synLoop    = new Object;
        enum   int  numWaiters = 10;
        enum   int  numTries   = 10;
        shared int  numReady   = 0;
        shared int  numTotal   = 0;
        shared int  numDone    = 0;

        void waiter()
        {
            for( int i = 0; i < numTries; ++i )
            {
                synchronized( mutex )
                {
                    while( numReady.assumeUnshared < 1 )
                    {
                        condReady.wait();
                    }
                    --numReady.assumeUnshared;
                    ++numTotal.assumeUnshared;
                }

                synchronized( synLoop )
                {
                    ++numDone.assumeUnshared;
                }
                semDone.wait();
            }
        }

        auto group = new ThreadGroup;

        for( int i = 0; i < numWaiters; ++i )
            group.create( &waiter );

        for( int i = 0; i < numTries; ++i )
        {
            for( int j = 0; j < numWaiters; ++j )
            {
                synchronized( mutex )
                {
                    ++numReady.assumeUnshared;
                    condReady.notify();
                }
            }
            while( true )
            {
                synchronized( synLoop )
                {
                    if( numDone.assumeUnshared >= numWaiters )
                        break;
                }
                Thread.yield();
            }
            for( int j = 0; j < numWaiters; ++j )
            {
                semDone.notify();
            }
        }

        group.joinAll();
        assert( numTotal.assumeUnshared == numWaiters * numTries );
    }


    void testNotifyAll()
    {
        auto        mutex      = new Mutex;
        auto        condReady  = new Condition( mutex );
        enum int    numWaiters = 10;
        shared int  numReady   = 0;
        shared int  numDone    = 0;
        shared bool alert      = false;

        void waiter()
        {
            synchronized( mutex )
            {
                ++numReady.assumeUnshared;
                while( !alert.assumeUnshared )
                    condReady.wait();
                ++numDone.assumeUnshared;
            }
        }

        auto group = new ThreadGroup;

        for( int i = 0; i < numWaiters; ++i )
            group.create( &waiter );

        while( true )
        {
            synchronized( mutex )
            {
                if( numReady.assumeUnshared >= numWaiters )
                {
                    alert.assumeUnshared = true;
                    condReady.notifyAll();
                    break;
                }
            }
            Thread.yield();
        }
        group.joinAll();
        assert( numReady.assumeUnshared == numWaiters && numDone.assumeUnshared == numWaiters );
    }


    void testWaitTimeout()
    {
        auto        mutex      = new Mutex;
        auto        condReady  = new Condition( mutex );
        shared bool waiting    = false;
        shared bool alertedOne = true;
        shared bool alertedTwo = true;

        void waiter()
        {
            synchronized( mutex )
            {
                waiting.assumeUnshared    = true;
                // we never want to miss the notification (30s)
                alertedOne.assumeUnshared = condReady.wait( dur!"seconds"(30) );
                // but we don't want to wait long for the timeout (10ms)
                alertedTwo.assumeUnshared = condReady.wait( dur!"msecs"(10) );
            }
        }

        auto thread = new Thread( &waiter );
        thread.start();

        while( true )
        {
            synchronized( mutex )
            {
                if( waiting.assumeUnshared )
                {
                    condReady.notify();
                    break;
                }
            }
            Thread.yield();
        }
        thread.join();
        assert( waiting.assumeUnshared );
        assert( alertedOne.assumeUnshared );
        assert( !alertedTwo.assumeUnshared );
    }


    unittest
    {
        testNotify();
        testNotifyAll();
        testWaitTimeout();
    }
}
