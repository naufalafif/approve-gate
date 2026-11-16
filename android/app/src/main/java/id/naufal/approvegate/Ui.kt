package id.naufal.approvegate

import android.app.Activity
import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat

/** Small view helpers: black, white and purple, no extra libraries.
 *  Spacing uses one scale (4, 8, 12, 16, 24, 32 dp) and a 20 dp page margin. */
object Ui {
    const val PURPLE = 0xFF6B3FD4.toInt()
    const val INK = 0xFF17131F.toInt()
    const val MUTED = 0xFF6B6578.toInt()
    const val SURFACE = 0xFFF4F1FB.toInt()
    const val LINE = 0xFFE4DEF2.toInt()
    const val DANGER = 0xFFC62828.toInt()
    const val DANGER_SURFACE = 0xFFFDECEC.toInt()
    const val OK = 0xFF2E7D32.toInt()
    const val WARN = 0xFFB26A00.toInt()
    const val WARN_SURFACE = 0xFFFFF4E0.toInt()
    const val PAGE = 20

    fun dp(ctx: Context, v: Int) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), ctx.resources.displayMetrics).toInt()

    /** Sets the screen: scrolling content, plus an optional bar pinned to the bottom. Insets are
     *  applied by hand because targetSdk 36 draws edge to edge, and fitsSystemWindows loses them
     *  when the screen is rebuilt (the title slid under the status bar after a dialog). */
    fun screen(a: Activity, content: View, bottom: View? = null) {
        val root = LinearLayout(a).apply { orientation = LinearLayout.VERTICAL; setBackgroundColor(Color.WHITE) }
        root.addView(ScrollView(a).apply { addView(content); isFillViewport = true; clipToPadding = false },
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        if (bottom != null) {
            root.addView(View(a).apply { setBackgroundColor(LINE) }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(a, 1)))
            root.addView(bottom)
        }
        ViewCompat.setOnApplyWindowInsetsListener(root) { v, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
            v.setPadding(bars.left, bars.top, bars.right, bars.bottom)
            WindowInsetsCompat.CONSUMED
        }
        a.setContentView(root)
        ViewCompat.requestApplyInsets(root)
    }

    fun column(ctx: Context, top: Int = 16, bottom: Int = 32) = LinearLayout(ctx).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(ctx, PAGE), dp(ctx, top), dp(ctx, PAGE), dp(ctx, bottom))
    }

    fun row(ctx: Context) = LinearLayout(ctx).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
    }

    fun text(ctx: Context, s: String, size: Float = 15f, color: Int = INK, bold: Boolean = false, mono: Boolean = false) =
        TextView(ctx).apply {
            text = s
            textSize = size
            setTextColor(color)
            typeface = when {
                mono -> Typeface.MONOSPACE
                bold -> Typeface.create("sans-serif-medium", Typeface.NORMAL)
                else -> Typeface.DEFAULT
            }
            setLineSpacing(0f, 1.2f)
        }

    fun oneLine(t: TextView) = t.apply { maxLines = 1; ellipsize = TextUtils.TruncateAt.END }

    /** Section heading: small caps, with the gap above it and a small gap to its content. */
    fun label(ctx: Context, s: String, top: Int = 24) = text(ctx, s.uppercase(), 12f, MUTED, bold = true).apply {
        letterSpacing = 0.08f
        setPadding(0, dp(ctx, top), 0, dp(ctx, 8))
    }

    fun card(ctx: Context, fill: Int = SURFACE, stroke: Int? = null) = LinearLayout(ctx).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(ctx, 16), dp(ctx, 16), dp(ctx, 16), dp(ctx, 16))
        background = GradientDrawable().apply {
            setColor(fill)
            cornerRadius = dp(ctx, 16).toFloat()
            stroke?.let { setStroke(dp(ctx, 1), it) }
        }
    }

    fun dot(ctx: Context, color: Int, size: Int = 10) = View(ctx).apply {
        background = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(color) }
        layoutParams = LinearLayout.LayoutParams(dp(ctx, size), dp(ctx, size)).apply { marginEnd = dp(ctx, 12) }
    }

    fun badge(ctx: Context, s: String, color: Int) = text(ctx, s, 12f, Color.WHITE, bold = true).apply {
        letterSpacing = 0.06f
        setPadding(dp(ctx, 10), dp(ctx, 4), dp(ctx, 10), dp(ctx, 4))
        background = GradientDrawable().apply { setColor(color); cornerRadius = dp(ctx, 99).toFloat() }
    }

    fun divider(ctx: Context) = View(ctx).apply {
        setBackgroundColor(LINE)
        layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(ctx, 1))
    }

    enum class Kind { PRIMARY, SECONDARY, DANGER_TEXT }

    fun button(ctx: Context, s: String, kind: Kind, onClick: () -> Unit) = Button(ctx).apply {
        text = s
        isAllCaps = false
        textSize = 16f
        stateListAnimator = null
        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        setTextColor(when (kind) { Kind.PRIMARY -> Color.WHITE; Kind.SECONDARY -> INK; Kind.DANGER_TEXT -> DANGER })
        background = GradientDrawable().apply {
            cornerRadius = dp(ctx, 12).toFloat()
            when (kind) {
                Kind.PRIMARY -> setColor(PURPLE)
                Kind.SECONDARY -> { setColor(Color.WHITE); setStroke(dp(ctx, 1), LINE) }
                Kind.DANGER_TEXT -> setColor(Color.TRANSPARENT)
            }
        }
        minHeight = dp(ctx, 52)
        minimumHeight = dp(ctx, 52)
        gravity = Gravity.CENTER
        setOnClickListener { onClick() }
    }

    fun button(ctx: Context, s: String, primary: Boolean, onClick: () -> Unit) =
        button(ctx, s, if (primary) Kind.PRIMARY else Kind.SECONDARY, onClick)

    fun lp(ctx: Context, top: Int = 0, weight: Float = 0f, width: Int = LinearLayout.LayoutParams.MATCH_PARENT) =
        LinearLayout.LayoutParams(if (weight > 0) 0 else width, LinearLayout.LayoutParams.WRAP_CONTENT, weight).apply {
            topMargin = dp(ctx, top)
        }
}
