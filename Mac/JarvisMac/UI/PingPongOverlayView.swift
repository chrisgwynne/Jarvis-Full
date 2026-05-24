import SwiftUI

// MARK: - PingPongGame

@MainActor
@Observable
final class PingPongGame {

    // Ball (normalized 0–1 within canvas)
    var ballX: CGFloat = 0.5
    var ballY: CGFloat = 0.5
    var velX:  CGFloat = 0.0
    var velY:  CGFloat = 0.0

    // Paddle Y centres (normalized, 0 = top)
    var leftPaddleY:  CGFloat = 0.5
    var rightPaddleY: CGFloat = 0.5

    // Scores
    var leftScore:  Int = 0
    var rightScore: Int = 0

    // Lifecycle
    var running:      Bool   = false
    var gameOver:     Bool   = false
    var winningSide:  String = ""
    var flashLeft:    Bool   = false
    var flashRight:   Bool   = false

    // Geometry constants (fraction of canvas)
    let paddleH:    CGFloat = 0.16
    let paddleW:    CGFloat = 0.022
    let paddleEdge: CGFloat = 0.030
    let ballR:      CGFloat = 0.014
    let maxScore:   Int     = 7

    // Starting speed (canvas-widths per second)
    private let baseSpeed: CGFloat = 0.40
    private let maxSpeed:  CGFloat = 0.95

    func start() {
        leftScore  = 0
        rightScore = 0
        gameOver   = false
        leftPaddleY  = 0.5
        rightPaddleY = 0.5
        launchBall(towardRight: Bool.random())
        running = true
    }

    func tick(dt: TimeInterval) {
        guard running else { return }
        let s = CGFloat(min(dt, 0.033))

        ballX += velX * s
        ballY += velY * s

        // Top / bottom wall bounce
        if ballY < ballR {
            ballY = ballR
            velY  = abs(velY)
        } else if ballY > 1 - ballR {
            ballY = 1 - ballR
            velY  = -abs(velY)
        }

        // ── Left paddle ──────────────────────────────────────────────────────
        let leftFace = paddleEdge + paddleW
        if velX < 0, ballX <= leftFace + ballR, ballX >= paddleEdge - ballR {
            if abs(ballY - leftPaddleY) < (paddleH + ballR) / 2 {
                let rel = (ballY - leftPaddleY) / (paddleH / 2)    // −1…1
                ballX = leftFace + ballR
                velX  = min(abs(velX) * 1.05, maxSpeed)
                velY  = rel * 0.42 + velY * 0.25
            }
        }

        // ── Right paddle ─────────────────────────────────────────────────────
        let rightFace = 1 - paddleEdge - paddleW
        if velX > 0, ballX >= rightFace - ballR, ballX <= 1 - paddleEdge + ballR {
            if abs(ballY - rightPaddleY) < (paddleH + ballR) / 2 {
                let rel = (ballY - rightPaddleY) / (paddleH / 2)
                ballX = rightFace - ballR
                velX  = -min(abs(velX) * 1.05, maxSpeed)
                velY  = rel * 0.42 + velY * 0.25
            }
        }

        // ── Score ─────────────────────────────────────────────────────────────
        if ballX < -ballR {
            rightScore += 1
            triggerFlash(right: true)
            if rightScore >= maxScore { endGame(winner: "Right") }
            else { launchBall(towardRight: true) }
        } else if ballX > 1 + ballR {
            leftScore += 1
            triggerFlash(right: false)
            if leftScore >= maxScore { endGame(winner: "Left") }
            else { launchBall(towardRight: false) }
        }

    }

    private func launchBall(towardRight: Bool) {
        ballX = 0.5
        ballY = CGFloat.random(in: 0.35...0.65)
        velX  = towardRight ? baseSpeed : -baseSpeed
        velY  = CGFloat.random(in: -0.28...0.28)
    }

    private func endGame(winner: String) {
        running     = false
        gameOver    = true
        winningSide = winner
    }

    private func triggerFlash(right: Bool) {
        if right {
            flashRight = true
            Task { try? await Task.sleep(for: .seconds(0.45)); flashRight = false }
        } else {
            flashLeft = true
            Task { try? await Task.sleep(for: .seconds(0.45)); flashLeft = false }
        }
    }
}

// MARK: - PingPongOverlayView

struct PingPongOverlayView: View {

    let coordinator: SpatialAmbientCoordinator

    @State private var game       = PingPongGame()
    @State private var lastTick   = Date()
    @State private var tickActive = false

    private let gameTimer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {

            // ── Field ──────────────────────────────────────────────────────────
            Color(red: 0.04, green: 0.04, blue: 0.09)
                .ignoresSafeArea()

            Canvas { ctx, size in
                drawField(ctx: ctx, size: size)
                drawPaddles(ctx: ctx, size: size)
                if game.running { drawBall(ctx: ctx, size: size) }
            }

            // ── Scores ─────────────────────────────────────────────────────────
            VStack(spacing: 0) {
                HStack {
                    Text("\(game.leftScore)")
                        .font(.system(size: 56, weight: .bold, design: .monospaced))
                        .foregroundStyle(game.flashLeft ? Color.yellow : Color.white)
                        .animation(.easeOut(duration: 0.3), value: game.flashLeft)
                        .frame(maxWidth: .infinity, alignment: .center)

                    Text(":")
                        .font(.system(size: 56, weight: .thin))
                        .foregroundStyle(.white.opacity(0.25))

                    Text("\(game.rightScore)")
                        .font(.system(size: 56, weight: .bold, design: .monospaced))
                        .foregroundStyle(game.flashRight ? Color.yellow : Color.white)
                        .animation(.easeOut(duration: 0.3), value: game.flashRight)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(.top, 20)
                Spacer()
            }

            // ── Tracking indicator ─────────────────────────────────────────────
            if game.running {
                VStack {
                    Spacer()
                    trackingStatus
                        .padding(.bottom, 12)
                }
            }

            // ── Start / game-over screen ───────────────────────────────────────
            if !game.running {
                splashScreen
            }
        }
        .onAppear {
            // Both hands are used as paddles — disable the coordinator's
            // two-hand resize gesture so moving hands doesn't resize the overlay.
            coordinator.suppressSecondHandGestures = true
        }
        .onDisappear {
            coordinator.suppressSecondHandGestures = false
        }
        .onReceive(gameTimer) { now in
            guard game.running else { lastTick = now; return }
            let dt = now.timeIntervalSince(lastTick)
            lastTick = now
            updatePaddles()
            game.tick(dt: dt)
        }
    }

    // MARK: - Paddle input from hands

    private func updatePaddles() {
        let primary   = coordinator.tracker.handPose
        let secondary = coordinator.tracker.secondaryHandPose

        let smoothing: CGFloat = 0.18

        for pose in [primary, secondary].compactMap({ $0 }) {
            // Vision Y: 0 = bottom → game Y (0 = top) = 1 − vision_y
            let gameY = CGFloat(1.0 - pose.wrist.y)
            let padH  = game.paddleH
            let clamped = max(padH / 2, min(1 - padH / 2, gameY))

            // Vision X > 0.5 → right side of camera image → physical LEFT hand
            if pose.wrist.x > 0.5 {
                game.leftPaddleY += (clamped - game.leftPaddleY) * smoothing
            } else {
                game.rightPaddleY += (clamped - game.rightPaddleY) * smoothing
            }
        }
    }

    // MARK: - Splash

    @ViewBuilder
    private var splashScreen: some View {
        VStack(spacing: 22) {
            if game.gameOver {
                Text("\(game.winningSide) wins!")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(.white)
                Text("\(game.leftScore)  —  \(game.rightScore)")
                    .font(.system(size: 24, weight: .light, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
            } else {
                Image(systemName: "hand.raised.fingers.spread.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.cyan)
                Text("Ping Pong")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(.white)
                VStack(spacing: 6) {
                    Text("Raise both hands to control your paddle")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.55))
                    Text("Left hand = left paddle · Right hand = right paddle")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.35))
                    Text("First to \(game.maxScore) wins")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.35))
                }
            }

            Button(game.gameOver ? "Play Again" : "Start Game") {
                lastTick = Date()
                game.start()
            }
            .buttonStyle(.borderedProminent)
            .tint(.cyan)
            .font(.title3.weight(.semibold))
            .controlSize(.large)
        }
        .padding(44)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    // MARK: - Tracking status badge

    private var trackingStatus: some View {
        let primary   = coordinator.tracker.handPose
        let secondary = coordinator.tracker.secondaryHandPose
        let bothDetected = primary != nil && secondary != nil
        let oneDetected  = (primary != nil) != (secondary != nil)

        let label: String
        let dot: Color
        if bothDetected {
            label = "Both hands tracked"
            dot   = .green
        } else if oneDetected {
            label = "One hand detected — raise both hands"
            dot   = .yellow
        } else {
            label = "No hands detected — raise both hands"
            dot   = .red.opacity(0.7)
        }

        return HStack(spacing: 6) {
            Circle().fill(dot).frame(width: 7, height: 7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.45))
        }
    }

    // MARK: - Canvas drawing

    private func drawField(ctx: GraphicsContext, size: CGSize) {
        // Dashed centre line
        let cx    = size.width / 2
        let dashH: CGFloat = 14
        let gap:   CGFloat = 10
        var y: CGFloat = 0
        while y < size.height {
            ctx.fill(
                Path(CGRect(x: cx - 2, y: y, width: 4, height: min(dashH, size.height - y))),
                with: .color(.white.opacity(0.12))
            )
            y += dashH + gap
        }
    }

    private func drawPaddles(ctx: GraphicsContext, size: CGSize) {
        let pW = size.width  * game.paddleW
        let pH = size.height * game.paddleH

        func paddle(at rect: CGRect, color: Color) {
            let rr = RoundedRectangle(cornerRadius: pW / 2)
            // Glow
            ctx.drawLayer { g in
                g.addFilter(.blur(radius: 9))
                let gRect = rect.insetBy(dx: -5, dy: -5)
                g.fill(rr.path(in: gRect), with: .color(color.opacity(0.55)))
            }
            // Solid bar
            ctx.fill(rr.path(in: rect), with: .color(color))
        }

        let leftX = size.width * game.paddleEdge
        let leftY = game.leftPaddleY * size.height - pH / 2
        paddle(at: CGRect(x: leftX, y: leftY, width: pW, height: pH), color: .cyan)

        let rightX = size.width * (1 - game.paddleEdge) - pW
        let rightY = game.rightPaddleY * size.height - pH / 2
        paddle(at: CGRect(x: rightX, y: rightY, width: pW, height: pH), color: .orange)
    }

    private func drawBall(ctx: GraphicsContext, size: CGSize) {
        let r  = min(size.width, size.height) * game.ballR
        let bx = game.ballX * size.width  - r
        let by = game.ballY * size.height - r
        let ballRect = CGRect(x: bx, y: by, width: r * 2, height: r * 2)

        // Glow
        ctx.drawLayer { g in
            g.addFilter(.blur(radius: 12))
            let gRect = ballRect.insetBy(dx: -5, dy: -5)
            g.fill(Path(ellipseIn: gRect), with: .color(.white.opacity(0.65)))
        }
        // Core
        ctx.fill(Path(ellipseIn: ballRect), with: .color(.white))
    }
}
