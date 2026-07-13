package uz.bunyod.esp32alarm

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothSocket
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.widget.Button
import android.widget.TextView
import android.widget.TimePicker
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import java.io.OutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID
import kotlin.concurrent.thread

class MainActivity : AppCompatActivity() {

    companion object {
        const val DEVICE_NAME = "ESP32-Alarm"
        val SPP_UUID: UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
        const val PERM_REQUEST = 101
    }

    private var socket: BluetoothSocket? = null
    private var output: OutputStream? = null

    private lateinit var statusText: TextView
    private lateinit var connectBtn: Button
    private lateinit var sendAlarmBtn: Button
    private lateinit var stopBtn: Button
    private lateinit var timePicker: TimePicker

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        statusText = findViewById(R.id.statusText)
        connectBtn = findViewById(R.id.connectBtn)
        sendAlarmBtn = findViewById(R.id.sendAlarmBtn)
        stopBtn = findViewById(R.id.stopBtn)
        timePicker = findViewById(R.id.timePicker)
        timePicker.setIs24HourView(true)

        connectBtn.setOnClickListener {
            if (socket?.isConnected == true) disconnect() else checkPermissionAndConnect()
        }

        sendAlarmBtn.setOnClickListener {
            val h = timePicker.hour
            val m = timePicker.minute
            sendCommand(String.format(Locale.US, "A %02d:%02d:00", h, m))
        }

        stopBtn.setOnClickListener {
            sendCommand("STOP")
        }
    }

    private fun checkPermissionAndConnect() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_CONNECT)
                != PackageManager.PERMISSION_GRANTED
            ) {
                ActivityCompat.requestPermissions(
                    this, arrayOf(Manifest.permission.BLUETOOTH_CONNECT), PERM_REQUEST
                )
                return
            }
        }
        connect()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == PERM_REQUEST &&
            grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        ) {
            connect()
        } else {
            toast("Bluetooth ruxsati berilmadi")
        }
    }

    @SuppressLint("MissingPermission")
    private fun connect() {
        val adapter = BluetoothAdapter.getDefaultAdapter()
        if (adapter == null) { toast("Bu telefonda Bluetooth yo'q"); return }
        if (!adapter.isEnabled) { toast("Avval Bluetooth'ni yoqing"); return }

        val device = adapter.bondedDevices.firstOrNull { it.name == DEVICE_NAME }
        if (device == null) {
            toast("$DEVICE_NAME topilmadi. Avval telefon sozlamalarida pair qiling!")
            return
        }

        statusText.text = "Ulanmoqda..."
        connectBtn.isEnabled = false

        thread {
            try {
                adapter.cancelDiscovery()
                val s = device.createRfcommSocketToServiceRecord(SPP_UUID)
                s.connect()
                socket = s
                output = s.outputStream

                // Ulangan zahoti telefonning joriy vaqtini yuborish
                val now = SimpleDateFormat("HH:mm:ss", Locale.US).format(Date())
                output?.write("T $now\n".toByteArray())

                runOnUiThread {
                    statusText.text = "Ulandi ✓ (joriy vaqt yuborildi: $now)"
                    connectBtn.text = "Uzish"
                    connectBtn.isEnabled = true
                    sendAlarmBtn.isEnabled = true
                    stopBtn.isEnabled = true
                }
            } catch (e: Exception) {
                runOnUiThread {
                    statusText.text = "Ulanib bo'lmadi: ${e.message}"
                    connectBtn.isEnabled = true
                }
            }
        }
    }

    private fun sendCommand(cmd: String) {
        if (socket?.isConnected != true) { toast("Avval ulaning"); return }
        thread {
            try {
                output?.write("$cmd\n".toByteArray())
                runOnUiThread {
                    statusText.text = "Yuborildi: $cmd"
                }
            } catch (e: Exception) {
                runOnUiThread {
                    statusText.text = "Yuborishda xato: ${e.message}"
                    disconnect()
                }
            }
        }
    }

    private fun disconnect() {
        try { socket?.close() } catch (_: Exception) {}
        socket = null
        output = null
        statusText.text = "Uzildi"
        connectBtn.text = "Ulanish"
        sendAlarmBtn.isEnabled = false
        stopBtn.isEnabled = false
    }

    private fun toast(msg: String) =
        Toast.makeText(this, msg, Toast.LENGTH_SHORT).show()

    override fun onDestroy() {
        super.onDestroy()
        disconnect()
    }
}
