import Foundation

/// Position and velocity in the TEME frame (true equator, mean equinox of date), kilometres and kilometres per second.
public struct StateVector: Sendable, Equatable {
    public var position: Vector3
    public var velocity: Vector3

    public init(position: Vector3, velocity: Vector3) {
        self.position = position
        self.velocity = velocity
    }
}

public enum SGP4Error: Error, Equatable {
    /// Periods of 225 minutes and more need the deep-space (SDP4) terms, which this phase does not implement.
    case unsupportedDeepSpace(periodMinutes: Double)
    case meanElementsOutOfRange
    case perturbedElementsOutOfRange
    case semiLatusRectumNegative
    case decayed
    case nonFiniteInput
}

/// Near-Earth SGP4, written from the published equations (Hoots and Roehrich, Spacetrack Report No. 3, 1980, with the
/// corrections of Vallado, Crawford, Hujsak and Kelso, "Revisiting Spacetrack Report #3", AIAA 2006-6753), in the
/// AFSPC operation mode with the WGS-72 constants those element sets are fitted with. It was checked against reference
/// output (the official verification set through python-sgp4), not derived from any implementation's source.
public struct SGP4Propagator: Sendable {
    public let epoch: Date

    // WGS-72, the gravity model SGP4 element sets assume.
    private static let earthRadiusKM = 6378.135
    private static let mu = 398_600.8
    private static let xke = 60.0 / (earthRadiusKM * earthRadiusKM * earthRadiusKM / mu).squareRoot()
    private static let j2 = 0.001082616
    private static let j3 = -0.00000253881
    private static let j4 = -0.00000165597
    private static let j3OverJ2 = j3 / j2
    private static let twoThirds = 2.0 / 3.0

    // Elements at epoch (radians; no is the un-Kozai'd mean motion in rad/min).
    private let ecco: Double
    private let inclo: Double
    private let nodeo: Double
    private let argpo: Double
    private let mo: Double
    private let no: Double
    private let bstar: Double

    // Constants fixed by the elements.
    private let isSimple: Bool
    private let eta: Double
    private let cc1: Double, cc4: Double, cc5: Double
    private let d2: Double, d3: Double, d4: Double
    private let t2cof: Double, t3cof: Double, t4cof: Double, t5cof: Double
    private let mdot: Double, argpdot: Double, nodedot: Double, nodecf: Double
    private let omgcof: Double, xmcof: Double, delmo: Double, sinmao: Double
    private let aycof: Double, xlcof: Double, con41: Double, x1mth2: Double, x7thm1: Double

    public init(_ elements: OrbitalElements) throws {
        let numbers = [elements.eccentricity, elements.inclinationDegrees, elements.raanDegrees,
                       elements.argumentOfPerigeeDegrees, elements.meanAnomalyDegrees,
                       elements.meanMotionRevsPerDay, elements.bstar]
        guard numbers.allSatisfy({ $0.isFinite }), elements.epoch.timeIntervalSince1970.isFinite else {
            throw SGP4Error.nonFiniteInput
        }
        guard (0..<1).contains(elements.eccentricity), elements.meanMotionRevsPerDay > 0 else {
            throw SGP4Error.meanElementsOutOfRange
        }
        let xke = Self.xke, j2 = Self.j2, j3oj2 = Self.j3OverJ2, j4 = Self.j4, x2o3 = Self.twoThirds
        let re = Self.earthRadiusKM
        let degrees = Double.pi / 180

        epoch = elements.epoch
        ecco = elements.eccentricity
        inclo = elements.inclinationDegrees * degrees
        nodeo = elements.raanDegrees * degrees
        argpo = elements.argumentOfPerigeeDegrees * degrees
        mo = elements.meanAnomalyDegrees * degrees
        bstar = elements.bstar
        let noKozai = elements.meanMotionRevsPerDay * 2 * .pi / 1440

        // Recover the original mean motion from the Kozai mean motion the element sets publish.
        let eccsq = ecco * ecco
        let omeosq = 1 - eccsq
        let rteosq = omeosq.squareRoot()
        let cosio = cos(inclo)
        let cosio2 = cosio * cosio
        let ak = pow(xke / noKozai, x2o3)
        let d1 = 0.75 * j2 * (3 * cosio2 - 1) / (rteosq * omeosq)
        var del = d1 / (ak * ak)
        let adel = ak * (1 - del * del - del * (1.0 / 3.0 + 134 * del * del / 81))
        del = d1 / (adel * adel)
        no = noKozai / (1 + del)

        let period = 2 * Double.pi / no
        guard period < 225 else { throw SGP4Error.unsupportedDeepSpace(periodMinutes: period) }

        let ao = pow(xke / no, x2o3)
        let sinio = sin(inclo)
        let po = ao * omeosq
        let con42 = 1 - 5 * cosio2
        con41 = -con42 - cosio2 - cosio2
        let posq = po * po
        let rp = ao * (1 - ecco)

        // Below 220 km the drag series is truncated; below 156 km the atmosphere-model constants change too.
        isSimple = rp < 220 / re + 1
        var sfour = 78 / re + 1
        var qzms24 = pow((120 - 78) / re, 4)
        let perige = (rp - 1) * re
        if perige < 156 {
            sfour = perige - 78
            if perige < 98 { sfour = 20 }
            qzms24 = pow((120 - sfour) / re, 4)
            sfour = sfour / re + 1
        }
        let pinvsq = 1 / posq
        let tsi = 1 / (ao - sfour)
        eta = ao * ecco * tsi
        let etasq = eta * eta
        let eeta = ecco * eta
        let psisq = abs(1 - etasq)
        let coef = qzms24 * pow(tsi, 4)
        let coef1 = coef / pow(psisq, 3.5)
        let cc2 = coef1 * no * (ao * (1 + 1.5 * etasq + eeta * (4 + etasq))
            + 0.375 * j2 * tsi / psisq * con41 * (8 + 3 * etasq * (8 + etasq)))
        cc1 = bstar * cc2
        let cc3 = ecco > 1e-4 ? -2 * coef * tsi * j3oj2 * no * sinio / ecco : 0
        x1mth2 = 1 - cosio2
        cc4 = 2 * no * coef1 * ao * omeosq * (eta * (2 + 0.5 * etasq) + ecco * (0.5 + 2 * etasq)
            - j2 * tsi / (ao * psisq) * (-3 * con41 * (1 - 2 * eeta + etasq * (1.5 - 0.5 * eeta))
                + 0.75 * x1mth2 * (2 * etasq - eeta * (1 + etasq)) * cos(2 * argpo)))
        cc5 = 2 * coef1 * ao * omeosq * (1 + 2.75 * (etasq + eeta) + eeta * etasq)

        // Secular rates from J2, J2 squared and J4.
        let cosio4 = cosio2 * cosio2
        let temp1 = 1.5 * j2 * pinvsq * no
        let temp2 = 0.5 * temp1 * j2 * pinvsq
        let temp3 = -0.46875 * j4 * pinvsq * pinvsq * no
        mdot = no + 0.5 * temp1 * rteosq * con41 + 0.0625 * temp2 * rteosq * (13 - 78 * cosio2 + 137 * cosio4)
        argpdot = -0.5 * temp1 * con42 + 0.0625 * temp2 * (7 - 114 * cosio2 + 395 * cosio4)
            + temp3 * (3 - 36 * cosio2 + 49 * cosio4)
        let xhdot1 = -temp1 * cosio
        nodedot = xhdot1 + (0.5 * temp2 * (4 - 19 * cosio2) + 2 * temp3 * (3 - 7 * cosio2)) * cosio
        omgcof = bstar * cc3 * cos(argpo)
        xmcof = ecco > 1e-4 ? -x2o3 * coef * bstar / eeta : 0
        nodecf = 3.5 * omeosq * xhdot1 * cc1
        t2cof = 1.5 * cc1
        // 1 + cos(i) vanishes at an inclination of exactly 180 degrees.
        xlcof = abs(cosio + 1) > 1.5e-12
            ? -0.25 * j3oj2 * sinio * (3 + 5 * cosio) / (1 + cosio)
            : -0.25 * j3oj2 * sinio * (3 + 5 * cosio) / 1.5e-12
        aycof = -0.5 * j3oj2 * sinio
        let delmotemp = 1 + eta * cos(mo)
        delmo = delmotemp * delmotemp * delmotemp
        sinmao = sin(mo)
        x7thm1 = 7 * cosio2 - 1

        if !isSimple {
            let cc1sq = cc1 * cc1
            d2 = 4 * ao * tsi * cc1sq
            let temp = d2 * tsi * cc1 / 3
            d3 = (17 * ao + sfour) * temp
            d4 = 0.5 * temp * ao * tsi * (221 * ao + 31 * sfour) * cc1
            t3cof = d2 + 2 * cc1sq
            t4cof = 0.25 * (3 * d3 + cc1 * (12 * d2 + 10 * cc1sq))
            t5cof = 0.2 * (3 * d4 + 12 * cc1 * d3 + 6 * d2 * d2 + 15 * cc1sq * (2 * d2 + cc1sq))
        } else {
            d2 = 0; d3 = 0; d4 = 0; t3cof = 0; t4cof = 0; t5cof = 0
        }
    }

    public func state(at date: Date) throws -> StateVector {
        try state(minutesSinceEpoch: date.timeIntervalSince(epoch) / 60)
    }

    public func state(minutesSinceEpoch t: Double) throws -> StateVector {
        guard t.isFinite else { throw SGP4Error.nonFiniteInput }
        let xke = Self.xke, j2 = Self.j2, x2o3 = Self.twoThirds
        let twoPi = 2 * Double.pi

        // Secular gravity and atmospheric drag.
        let xmdf = mo + mdot * t
        let argpdf = argpo + argpdot * t
        let nodedf = nodeo + nodedot * t
        var argpm = argpdf
        var mm = xmdf
        let t2 = t * t
        var nodem = nodedf + nodecf * t2
        var tempa = 1 - cc1 * t
        var tempe = bstar * cc4 * t
        var templ = t2cof * t2

        if !isSimple {
            let delomg = omgcof * t
            let delmtemp = 1 + eta * cos(xmdf)
            let delm = xmcof * (delmtemp * delmtemp * delmtemp - delmo)
            let temp = delomg + delm
            mm = xmdf + temp
            argpm = argpdf - temp
            let t3 = t2 * t
            let t4 = t3 * t
            tempa = tempa - d2 * t2 - d3 * t3 - d4 * t4
            tempe += bstar * cc5 * (sin(mm) - sinmao)
            templ += t3cof * t3 + t4 * (t4cof + t * t5cof)
        }

        var nm = no
        var em = ecco
        guard nm > 0 else { throw SGP4Error.meanElementsOutOfRange }
        let am = pow(xke / nm, x2o3) * tempa * tempa
        nm = xke / pow(am, 1.5)
        em -= tempe
        guard em < 1, em >= -0.001 else { throw SGP4Error.meanElementsOutOfRange }
        if em < 1e-6 { em = 1e-6 }
        mm += no * templ
        var xlm = mm + argpm + nodem
        nodem = nodem.truncatingRemainder(dividingBy: twoPi)
        argpm = argpm.truncatingRemainder(dividingBy: twoPi)
        xlm = xlm.truncatingRemainder(dividingBy: twoPi)
        mm = (xlm - argpm - nodem).truncatingRemainder(dividingBy: twoPi)

        let sinip = sin(inclo)
        let cosip = cos(inclo)
        let ep = em
        let argpp = argpm
        let nodep = nodem
        let mp = mm

        // Long-period periodics.
        let axnl = ep * cos(argpp)
        var temp = 1 / (am * (1 - ep * ep))
        let aynl = ep * sin(argpp) + temp * aycof
        let xl = mp + argpp + nodep + temp * xlcof * axnl

        // Kepler's equation in the (u, axnl, aynl) form, with the correction clipped so a bad start cannot run away.
        let u = (xl - nodep).truncatingRemainder(dividingBy: twoPi)
        var eo1 = u
        var tem5 = 9999.9
        var iterations = 1
        var sineo1 = 0.0, coseo1 = 0.0
        while abs(tem5) >= 1e-12, iterations <= 10 {
            sineo1 = sin(eo1)
            coseo1 = cos(eo1)
            tem5 = 1 - coseo1 * axnl - sineo1 * aynl
            tem5 = (u - aynl * coseo1 + axnl * sineo1 - eo1) / tem5
            if abs(tem5) >= 0.95 { tem5 = tem5 > 0 ? 0.95 : -0.95 }
            eo1 += tem5
            iterations += 1
        }

        // Short-period preliminary quantities.
        let ecose = axnl * coseo1 + aynl * sineo1
        let esine = axnl * sineo1 - aynl * coseo1
        let el2 = axnl * axnl + aynl * aynl
        let pl = am * (1 - el2)
        guard pl >= 0 else { throw SGP4Error.semiLatusRectumNegative }
        let rl = am * (1 - ecose)
        let rdotl = am.squareRoot() * esine / rl
        let rvdotl = pl.squareRoot() / rl
        let betal = (1 - el2).squareRoot()
        temp = esine / (1 + betal)
        let sinu = am / rl * (sineo1 - aynl - axnl * temp)
        let cosu = am / rl * (coseo1 - axnl + aynl * temp)
        var su = atan2(sinu, cosu)
        let sin2u = (cosu + cosu) * sinu
        let cos2u = 1 - 2 * sinu * sinu
        temp = 1 / pl
        let temp1 = 0.5 * j2 * temp
        let temp2 = temp1 * temp

        // Short-period periodics.
        let mrt = rl * (1 - 1.5 * temp2 * betal * con41) + 0.5 * temp1 * x1mth2 * cos2u
        su -= 0.25 * temp2 * x7thm1 * sin2u
        let xnode = nodep + 1.5 * temp2 * cosip * sin2u
        let xinc = inclo + 1.5 * temp2 * cosip * sinip * cos2u
        let mvt = rdotl - nm * temp1 * x1mth2 * sin2u / xke
        let rvdot = rvdotl + nm * temp1 * (x1mth2 * cos2u + 1.5 * con41) / xke

        // Orientation vectors.
        let sinsu = sin(su), cossu = cos(su)
        let snod = sin(xnode), cnod = cos(xnode)
        let sini = sin(xinc), cosi = cos(xinc)
        let xmx = -snod * cosi
        let xmy = cnod * cosi
        let ux = xmx * sinsu + cnod * cossu
        let uy = xmy * sinsu + snod * cossu
        let uz = sini * sinsu
        let vx = xmx * cossu - cnod * sinsu
        let vy = xmy * cossu - snod * sinsu
        let vz = sini * cossu

        guard mrt >= 1 else { throw SGP4Error.decayed }
        let re = Self.earthRadiusKM
        let kmPerSecond = re * xke / 60
        let position = Vector3(mrt * re * ux, mrt * re * uy, mrt * re * uz)
        let velocity = Vector3((mvt * ux + rvdot * vx) * kmPerSecond,
                               (mvt * uy + rvdot * vy) * kmPerSecond,
                               (mvt * uz + rvdot * vz) * kmPerSecond)
        guard position.isFinite, velocity.isFinite else { throw SGP4Error.nonFiniteInput }
        return StateVector(position: position, velocity: velocity)
    }
}
