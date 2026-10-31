package com.lingzhi.bluedesk.relayandroid

import android.app.Application

class RelayApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        RelayEngine.init(this)
    }
}
