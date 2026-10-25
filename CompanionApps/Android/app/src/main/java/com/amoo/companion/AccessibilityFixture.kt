package com.amoo.companion

import android.app.Activity
import android.graphics.Color
import android.os.Build
import android.view.View
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.ScrollView
import android.widget.LinearLayout
import android.widget.TextView

/** Deterministic native controls qualifying audit findings, state assertions, and IME recovery. */
object AccessibilityFixture {
    fun addTo(activity: Activity, parent: LinearLayout, defects: Boolean) {
        fun size(dp: Int): Int = (dp * activity.resources.displayMetrics.density).toInt()
        fun state(view: View, description: String) {
            if (Build.VERSION.SDK_INT >= 30) view.stateDescription = description
        }
        parent.addView(TextView(activity).apply {
            id = R.id.fixture_audit_title
            text = "Accessibility fixture"
            textSize = 24f
            setTextColor(Color.BLACK)
        })
        parent.addView(CheckBox(activity).apply {
            minimumHeight = size(48)
            id = R.id.fixture_audit_checked
            text = "Receive updates"
            setTextColor(Color.BLACK)
            state(this, "Notifications off")
            setOnCheckedChangeListener { _, checked -> state(this, if (checked) "Notifications on" else "Notifications off") }
        })
        parent.addView(Button(activity).apply {
            id = R.id.fixture_audit_selected
            text = "Selectable option"
            isSelected = false
            setOnClickListener {
                isSelected = !isSelected
                state(this, if (isSelected) "Selected" else "Not selected")
            }
        })
        parent.addView(Button(activity).apply {
            id = R.id.fixture_audit_copy
            text = "Copy"
            state(this, "Ready")
            setOnClickListener { state(this, "Copied") }
        })
        val status = TextView(activity).apply {
            id = R.id.fixture_audit_status
            text = "No message sent"
            setTextColor(Color.BLACK)
        }
        val message = EditText(activity).apply {
            minimumHeight = size(48)
            id = R.id.fixture_audit_message
            hint = "Message"
            if (defects) contentDescription = "Message"
            setTextColor(Color.BLACK)
            isSingleLine = true
        }
        parent.addView(message)
        parent.addView(Button(activity).apply {
            id = R.id.fixture_audit_send
            text = "Send"
            setOnClickListener {
                status.text = "Sent: ${message.text}"
                message.text.clear()
            }
        })
        parent.addView(status)
        parent.addView(Button(activity).apply {
            id = R.id.fixture_audit_target
            text = if (defects) "" else "Accessible action"
            minimumHeight = 0
            minimumWidth = 0
            setPadding(0, 0, 0, 0)
            setOnClickListener { state(this, "Activated") }
        }, LinearLayout.LayoutParams(size(if (defects) 16 else 160), size(if (defects) 16 else 48)))
        if (activity.intent.data?.getBooleanQueryParameter("clipped", false) == true) {
            val content = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL }
            listOf("Clipped action one", "Clipped action two").forEach { title ->
                content.addView(Button(activity).apply { text = title },
                    LinearLayout.LayoutParams(size(200), size(48)))
            }
            parent.addView(ScrollView(activity).apply { addView(content) },
                LinearLayout.LayoutParams(size(240), size(56)))
        }
        parent.addView(TextView(activity).apply {
            id = R.id.fixture_audit_contrast
            text = "Contrast fixture text"
            textSize = 18f
            setTextColor(if (defects) Color.rgb(254, 254, 254) else Color.BLACK)
            setBackgroundColor(Color.WHITE)
        })
    }
}
