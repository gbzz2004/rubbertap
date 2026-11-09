"""
RubberTap yield forecasting: five models and ONE shared evaluation protocol.

Data: one row per block per 15-day tapping cycle (the cycle total in kg).

Evaluation protocol (identical for every model, see run_all_models):
  * Test set = the last H cycles (20% of the series, at least 3 and at most
    24 cycles). Nothing from the test set is used for training, scaling,
    SARIMA order selection or LSTM epoch selection.
  * Walk-forward (rolling-origin) one-step-ahead evaluation: to predict test
    cycle t, every model is re-trained on cycles 0..t-1 only and predicts
    cycle t. This is exactly how the app uses the models (forecast the next
    cycle from everything recorded so far).
  * MAE, RMSE, R2 and MAPE are computed on those out-of-sample predictions.
    Two naive baselines (last cycle, historical average) are scored on the
    same test cycles so the models can be judged against simple guessing.
  * Every feature only uses information available before the cycle being
    predicted: past yields, the previous cycle's weather, and the calendar
    position of the cycle being predicted.
  * Hyper-parameters (SARIMA order by AICc, LSTM epochs by an internal
    validation split) are chosen once on the data before the test set,
    then reused for every walk-forward refit.

Models:
  SARIMA           ARIMA chosen by AICc; yearly seasonality through Fourier
                   (harmonic) terms, plus seasonal AR/MA terms at lag 24
                   cycles once there are enough cycles (>= 56).
  LSTM             A real LSTM (gated recurrent network trained with
                   backpropagation through time), written in NumPy so it runs
                   on Python 3.15 and fits a small server. Ensemble of 3 seeds.
  SARIMA+LSTM      Hybrid (Zhang, 2003): SARIMA models the linear part, an
                   LSTM learns SARIMA's residuals.
  SARIMA+LightGBM  Same hybrid, with LightGBM learning the residuals.
  Random Forest    Baseline on lag features.
"""

import warnings
from dataclasses import dataclass

import lightgbm as lgb
import numpy as np
import pandas as pd
from sklearn.ensemble import RandomForestRegressor
from sklearn.metrics import mean_absolute_error, mean_squared_error, r2_score
from statsmodels.tsa.statespace.sarimax import SARIMAX
from statsmodels.tsa.stattools import kpss

warnings.filterwarnings("ignore")

CYCLE_DAYS = 15
CYCLES_PER_YEAR = 24          # 365 / 15 = 24.3
MIN_TRAIN_CYCLES = 12         # fewer than this before the test set: no evaluation
TEST_FRACTION = 0.2
MIN_TEST, MAX_TEST = 3, 24

# Ordinal encoding of the weather label (wetter = lower). Only the ORDER
# matters to the tree models; the LSTM sees it standardised.
WEATHER_FACTOR = {"Sunny": 1.0, "Cloudy": 0.95, "Windy": 0.85, "Rainy": 0.75}
DEFAULT_WEATHER = 0.9


# --------------------------------------------------------------------------
# Data
# --------------------------------------------------------------------------

def prepare_data(data: list) -> pd.DataFrame:
    """Supabase rows -> one row per cycle, sorted by date."""
    df = pd.DataFrame(data)
    df["date"] = pd.to_datetime(df["date"])
    df["yield_kg"] = pd.to_numeric(df["yield_kg"], errors="coerce")
    df = df.dropna(subset=["date", "yield_kg"])
    if "weather" not in df.columns:
        df["weather"] = None
    df["weather_factor"] = (
        df["weather"].map(WEATHER_FACTOR).fillna(DEFAULT_WEATHER).astype(float)
    )
    # A cycle entered more than once on the same date is treated as one total
    df = df.groupby("date", as_index=False).agg(
        yield_kg=("yield_kg", "sum"), weather_factor=("weather_factor", "mean")
    )
    return df.sort_values("date").reset_index(drop=True)


@dataclass
class History:
    y: np.ndarray
    dates: pd.DatetimeIndex
    weather: np.ndarray

    def __len__(self):
        return len(self.y)

    def head(self, n: int) -> "History":
        return History(self.y[:n], self.dates[:n], self.weather[:n])


def _season(dates, harmonics: int = 1) -> np.ndarray:
    """Yearly sin/cos terms for each date (position of the cycle in the year)."""
    doy = np.asarray(pd.DatetimeIndex(dates).dayofyear, dtype=float)
    angle = 2 * np.pi * doy / 365.25
    cols = []
    for k in range(1, harmonics + 1):
        cols += [np.sin(k * angle), np.cos(k * angle)]
    return np.column_stack(cols) if cols else np.empty((len(doy), 0))


def _future_dates(last_date, steps: int) -> pd.DatetimeIndex:
    return pd.DatetimeIndex(
        [last_date + pd.Timedelta(days=CYCLE_DAYS * k) for k in range(1, steps + 1)]
    )


# --------------------------------------------------------------------------
# SARIMA engine (shared by SARIMA and both hybrids; fits are cached)
# --------------------------------------------------------------------------

@dataclass(frozen=True)
class SarimaSpec:
    order: tuple
    seasonal_order: tuple = (0, 0, 0, 0)
    harmonics: int = 0
    trend: str = "n"

    def describe(self) -> str:
        p, d, q = self.order
        if self.seasonal_order[3]:
            P, D, Q, m = self.seasonal_order
            text = f"SARIMA({p},{d},{q})({P},{D},{Q})[{m}]"
        else:
            text = f"ARIMA({p},{d},{q})"
        if self.harmonics:
            text += f" + {self.harmonics} yearly harmonic" + ("s" if self.harmonics > 1 else "")
        if self.trend == "c":
            text += " with constant"
        return text


def _choose_d(y: np.ndarray) -> int:
    """Differencing order from the KPSS stationarity test (5% level)."""
    if len(y) < 12:
        return 0
    try:
        _, p_value, *_ = kpss(y, regression="c", nlags="auto")
        return 1 if p_value < 0.05 else 0
    except Exception:
        return 0


class SarimaEngine:
    """Fits SARIMA on the first n cycles of one series. Results are cached
    because SARIMA and both hybrids need the same fit."""

    def __init__(self, hist: History):
        self.hist = hist
        self._fits = {}

    def _exog(self, spec: SarimaSpec, dates):
        return _season(dates, spec.harmonics) if spec.harmonics else None

    def fit(self, n: int, spec: SarimaSpec):
        key = (n, spec)
        if key not in self._fits:
            h = self.hist.head(n)
            model = SARIMAX(
                h.y,
                exog=self._exog(spec, h.dates),
                order=spec.order,
                seasonal_order=spec.seasonal_order,
                trend=spec.trend,
            )
            self._fits[key] = model.fit(disp=False, maxiter=200)
        return self._fits[key]

    def forecast(self, n: int, spec: SarimaSpec, future_dates) -> np.ndarray:
        res = self.fit(n, spec)
        fc = res.forecast(steps=len(future_dates), exog=self._exog(spec, future_dates))
        return np.asarray(fc, dtype=float)

    def residuals(self, n: int, spec: SarimaSpec):
        """In-sample one-step residuals; the first `burn` values are unusable."""
        res = self.fit(n, spec)
        r = self.hist.y[:n] - np.asarray(res.fittedvalues, dtype=float)
        burn = max(int(getattr(res, "loglikelihood_burn", 0)), spec.order[1])
        return r, burn

    def select(self, n: int) -> SarimaSpec:
        """Pick the SARIMA spec with the lowest AICc on the first n cycles."""
        y = self.hist.y[:n]
        d = _choose_d(y)
        trend = "c" if d == 0 else "n"
        candidates = [
            SarimaSpec((p, d, q), (0, 0, 0, 0), k, trend)
            for k in (0, 1, 2) for p in (0, 1, 2) for q in (0, 1, 2)
        ]
        if n >= 2 * CYCLES_PER_YEAR + 8:
            candidates += [
                SarimaSpec((p, d, q), (P, 0, Q, CYCLES_PER_YEAR), 0, trend)
                for p in (0, 1) for q in (0, 1) for P, Q in ((1, 0), (0, 1))
            ]
        best, best_score = None, np.inf
        for spec in candidates:
            try:
                score = self.fit(n, spec).aicc
            except Exception:
                continue
            if np.isfinite(score) and score < best_score:
                best, best_score = spec, score
        return best or SarimaSpec((0, d, 0), trend=trend)


@dataclass
class RunContext:
    hist: History
    engine: SarimaEngine
    spec: SarimaSpec = None


# --------------------------------------------------------------------------
# A real LSTM in NumPy
# --------------------------------------------------------------------------

def _sigmoid(x):
    # Identical to 1 / (1 + exp(-x)), but faster and cannot overflow
    return 0.5 * (1.0 + np.tanh(0.5 * x))


class _LSTMNet:
    """Single-layer LSTM + linear output, trained with BPTT and Adam.
    Gates: input i, forget f, candidate g, output o.
        c_t = f*c_{t-1} + i*g,   h_t = o*tanh(c_t),   y = V.h_T + c
    """

    def __init__(self, n_in: int, n_hidden: int, seed: int):
        rng = np.random.default_rng(seed)
        H = n_hidden
        lim = 1.0 / np.sqrt(H)
        self.D, self.H = n_in, H
        self.p = {
            "W": rng.uniform(-lim, lim, (n_in + H, 4 * H)),
            "b": np.zeros(4 * H),
            "V": rng.uniform(-lim, lim, (H, 1)),
            "c": np.zeros(1),
        }
        self.p["b"][H:2 * H] = 1.0  # forget-gate bias 1: remember by default
        self._m = {k: np.zeros_like(v) for k, v in self.p.items()}
        self._v = {k: np.zeros_like(v) for k, v in self.p.items()}
        self._t = 0

    def _forward(self, X):
        B, T, _ = X.shape
        H, W, b = self.H, self.p["W"], self.p["b"]
        h, c = np.zeros((B, H)), np.zeros((B, H))
        cache = []
        for t in range(T):
            xh = np.concatenate([X[:, t, :], h], axis=1)
            z = xh @ W + b
            i = _sigmoid(z[:, :H])
            f = _sigmoid(z[:, H:2 * H])
            g = np.tanh(z[:, 2 * H:3 * H])
            o = _sigmoid(z[:, 3 * H:])
            c_new = f * c + i * g
            tc = np.tanh(c_new)
            h = o * tc
            cache.append((xh, i, f, g, o, c, tc))
            c = c_new
        out = (h @ self.p["V"]).ravel() + self.p["c"][0]
        return out, h, cache

    def predict(self, X):
        return self._forward(X)[0]

    def loss_and_grads(self, X, y, weight_decay=0.0):
        out, h_last, cache = self._forward(X)
        B, H, D = len(y), self.H, self.D
        err = out - y
        loss = np.mean(err ** 2) + 0.5 * weight_decay * (
            np.sum(self.p["W"] ** 2) + np.sum(self.p["V"] ** 2))
        dout = (2.0 / B) * err[:, None]
        W = self.p["W"]
        grads = {"V": h_last.T @ dout + weight_decay * self.p["V"], "c": dout.sum(axis=0)}
        dW, db = weight_decay * W, np.zeros(4 * H)
        dh, dc = dout @ self.p["V"].T, np.zeros((B, H))
        for xh, i, f, g, o, c_prev, tc in reversed(cache):
            do = dh * tc
            dc = dc + dh * o * (1 - tc ** 2)
            di, dg, df = dc * g, dc * i, dc * c_prev
            dz = np.concatenate(
                [di * i * (1 - i), df * f * (1 - f), dg * (1 - g ** 2), do * o * (1 - o)],
                axis=1)
            dW = dW + xh.T @ dz
            db = db + dz.sum(axis=0)
            dh = (dz @ W.T)[:, D:]
            dc = dc * f
        grads["W"], grads["b"] = dW, db
        return loss, grads

    def step(self, X, y, lr=0.01, weight_decay=1e-4, clip=1.0):
        loss, grads = self.loss_and_grads(X, y, weight_decay)
        norm = np.sqrt(sum(np.sum(g ** 2) for g in grads.values()))
        scale = clip / norm if norm > clip else 1.0
        self._t += 1
        b1, b2 = 0.9, 0.999
        for k, g in grads.items():
            g = g * scale
            self._m[k] = b1 * self._m[k] + (1 - b1) * g
            self._v[k] = b2 * self._v[k] + (1 - b2) * g ** 2
            m_hat = self._m[k] / (1 - b1 ** self._t)
            v_hat = self._v[k] / (1 - b2 ** self._t)
            self.p[k] -= lr * m_hat / (np.sqrt(v_hat) + 1e-8)
        return loss


class _SeqLearner:
    """Ensemble of LSTMs reading the last `window` rows of a feature matrix F
    and predicting the next value of column 0."""

    def __init__(self, window, hidden=12, seeds=(0, 1, 2), lr=0.01,
                 weight_decay=1e-4, max_epochs=300, check_every=20, default_epochs=150):
        self.window, self.hidden, self.seeds = window, hidden, seeds
        self.lr, self.weight_decay = lr, weight_decay
        self.max_epochs, self.check_every = max_epochs, check_every
        self.epochs = default_epochs
        self.nets = []

    def _windows(self, F):
        L = self.window
        X = np.stack([F[k - L:k] for k in range(L, len(F))])
        return X, F[L:, 0]

    def tune(self, F):
        """Choose the number of epochs on an internal validation split
        (the last 20% of the training windows). Never sees the test set."""
        X, y = self._windows(F)
        n_val = max(2, int(round(0.2 * len(y))))
        if len(y) - n_val < 6:
            return self.epochs
        Xtr, ytr, Xva, yva = X[:-n_val], y[:-n_val], X[-n_val:], y[-n_val:]
        checkpoints = list(range(self.check_every, self.max_epochs + 1, self.check_every))
        curve = np.zeros(len(checkpoints))
        for seed in self.seeds:
            net = _LSTMNet(F.shape[1], self.hidden, seed)
            j = 0
            for ep in range(1, self.max_epochs + 1):
                net.step(Xtr, ytr, self.lr, self.weight_decay)
                if ep % self.check_every == 0:
                    curve[j] += np.mean((net.predict(Xva) - yva) ** 2)
                    j += 1
        self.epochs = checkpoints[int(np.argmin(curve))]
        return self.epochs

    def fit(self, F):
        if len(F) - self.window < 6:
            raise ValueError("not enough cycles to train the LSTM")
        X, y = self._windows(F)
        self.nets = []
        for seed in self.seeds:
            net = _LSTMNet(F.shape[1], self.hidden, seed)
            for _ in range(self.epochs):
                net.step(X, y, self.lr, self.weight_decay)
            self.nets.append(net)

    def predict_next(self, F) -> float:
        Xw = F[-self.window:][None, :, :]
        return float(np.mean([net.predict(Xw)[0] for net in self.nets]))


# --------------------------------------------------------------------------
# Feature rows for the tree models (past information only)
# --------------------------------------------------------------------------

def _lag_row(y_past, w_past, target_date):
    """Features for predicting the cycle on target_date from earlier cycles."""
    l1, l2, l3 = y_past[-1], y_past[-2], y_past[-3]
    s = _season([target_date])[0]
    return [l1, l2, l3, (l1 + l2 + l3) / 3.0, l1 - l2, w_past[-1], s[0], s[1]]


def _resid_row(r_past, y_past, w_past, target_date):
    s = _season([target_date])[0]
    return [r_past[-1], r_past[-2], y_past[-1], y_past[-2], w_past[-1], s[0], s[1]]


# --------------------------------------------------------------------------
# The five models. Each has fit(ctx, n) on the first n cycles and
# predict(ctx, future_dates) -> array.
# --------------------------------------------------------------------------

class SarimaModel:
    key, name = "sarima", "SARIMA"

    def fit(self, ctx, n):
        self.n, self.spec = n, ctx.spec
        ctx.engine.fit(n, self.spec)

    def predict(self, ctx, future_dates):
        return ctx.engine.forecast(self.n, self.spec, future_dates)

    def details(self):
        return self.spec.describe()


class LSTMModel:
    key, name = "lstm", "LSTM"

    def __init__(self):
        self.learner = _SeqLearner(window=6)

    def _set_scale(self, h):
        self.mu, self.sd = h.y.mean(), h.y.std() or 1.0
        self.wmu, self.wsd = h.weather.mean(), h.weather.std() or 1.0

    def _features(self, y, dates, w):
        return np.column_stack([(y - self.mu) / self.sd, _season(dates), (w - self.wmu) / self.wsd])

    def tune(self, ctx, n):
        h = ctx.hist.head(n)
        self._set_scale(h)
        self.learner.tune(self._features(h.y, h.dates, h.weather))

    def fit(self, ctx, n):
        h = ctx.hist.head(n)
        self._set_scale(h)
        self.h = h
        self.learner.fit(self._features(h.y, h.dates, h.weather))

    def predict(self, ctx, future_dates):
        L = self.learner.window
        y, dates, w = list(self.h.y), list(self.h.dates), list(self.h.weather)
        out = []
        for d in future_dates:
            F = self._features(np.array(y[-L:]), pd.DatetimeIndex(dates[-L:]), np.array(w[-L:]))
            p = self.learner.predict_next(F) * self.sd + self.mu
            out.append(p)
            y.append(p); dates.append(d); w.append(self.wmu)
        return np.array(out)

    def details(self):
        l = self.learner
        return (f"LSTM, {l.hidden} memory cells, reads the last {l.window} cycles, "
                f"{l.epochs} training epochs, average of {len(l.seeds)} networks")


class SarimaLSTMModel:
    key, name = "sarima_lstm", "SARIMA+LSTM"

    def __init__(self):
        self.learner = _SeqLearner(window=4)

    def _residual_features(self, ctx, n, spec):
        r, burn = ctx.engine.residuals(n, spec)
        rr, dates = r[burn:], ctx.hist.dates[burn:n]
        self.rmu, self.rsd = rr.mean(), rr.std() or 1.0
        return rr, dates, np.column_stack([(rr - self.rmu) / self.rsd, _season(dates)])

    def tune(self, ctx, n):
        _, _, F = self._residual_features(ctx, n, ctx.spec)
        self.learner.tune(F)

    def fit(self, ctx, n):
        self.n, self.spec = n, ctx.spec
        self.rr, self.rdates, F = self._residual_features(ctx, n, self.spec)
        self.learner.fit(F)

    def predict(self, ctx, future_dates):
        base = ctx.engine.forecast(self.n, self.spec, future_dates)
        L = self.learner.window
        rz = list((self.rr - self.rmu) / self.rsd)
        dates = list(self.rdates)
        out = []
        for k, d in enumerate(future_dates):
            F = np.column_stack([np.array(rz[-L:]), _season(pd.DatetimeIndex(dates[-L:]))])
            z = self.learner.predict_next(F)
            out.append(base[k] + z * self.rsd + self.rmu)
            rz.append(z); dates.append(d)
        return np.array(out)

    def details(self):
        l = self.learner
        return (f"{self.spec.describe()}, then an LSTM ({l.hidden} cells, last {l.window} "
                f"cycles, {l.epochs} epochs) corrects its errors")


class SarimaLGBMModel:
    key, name = "sarima_lgbm", "SARIMA+LightGBM"

    def fit(self, ctx, n):
        self.n, self.spec = n, ctx.spec
        h = ctx.hist.head(n)
        r, burn = ctx.engine.residuals(n, self.spec)
        rows = range(burn + 2, n)
        X = [_resid_row(r[:t], h.y[:t], h.weather[:t], h.dates[t]) for t in rows]
        y = [r[t] for t in rows]
        self.r, self.h, self.w_mean = r, h, float(h.weather.mean())
        self.model = None
        if len(y) >= 8:
            self.model = lgb.LGBMRegressor(
                n_estimators=150, learning_rate=0.05, num_leaves=4, max_depth=2,
                min_child_samples=4, subsample=0.8, subsample_freq=1,
                colsample_bytree=0.8, reg_lambda=1.0, random_state=42,
                n_jobs=1, verbose=-1)
            self.model.fit(np.array(X), np.array(y))

    def predict(self, ctx, future_dates):
        base = ctx.engine.forecast(self.n, self.spec, future_dates)
        if self.model is None:
            return base
        r, y, w = list(self.r), list(self.h.y), list(self.h.weather)
        out = []
        for k, d in enumerate(future_dates):
            rhat = float(self.model.predict(np.array([_resid_row(r, y, w, d)]))[0])
            p = base[k] + rhat
            out.append(p)
            r.append(rhat); y.append(p); w.append(self.w_mean)
        return np.array(out)

    def details(self):
        return f"{self.spec.describe()}, then LightGBM corrects its errors"


class RandomForestModel:
    key, name = "random_forest", "Random Forest"

    def fit(self, ctx, n):
        h = ctx.hist.head(n)
        rows = range(3, n)
        if len(rows) < 4:
            raise ValueError("not enough cycles for Random Forest")
        X = [_lag_row(h.y[:t], h.weather[:t], h.dates[t]) for t in rows]
        y = [h.y[t] for t in rows]
        self.model = RandomForestRegressor(
            n_estimators=100, min_samples_leaf=2, random_state=42, n_jobs=1)
        self.model.fit(np.array(X), np.array(y))
        self.h, self.w_mean = h, float(h.weather.mean())

    def predict(self, ctx, future_dates):
        y, w = list(self.h.y), list(self.h.weather)
        out = []
        for d in future_dates:
            p = float(self.model.predict(np.array([_lag_row(y, w, d)]))[0])
            out.append(p)
            y.append(p); w.append(self.w_mean)
        return np.array(out)

    def details(self):
        return "Random Forest (100 trees) on the last 3 cycles, weather and time of year"


# --------------------------------------------------------------------------
# Evaluation and the public entry point
# --------------------------------------------------------------------------

def calculate_metrics(y_true, y_pred) -> dict:
    y_true, y_pred = np.asarray(y_true, float), np.asarray(y_pred, float)
    mae = mean_absolute_error(y_true, y_pred)
    rmse = np.sqrt(mean_squared_error(y_true, y_pred))
    r2 = r2_score(y_true, y_pred) if len(y_true) > 1 else 0.0
    nonzero = y_true != 0
    mape = np.mean(np.abs((y_true - y_pred)[nonzero] / y_true[nonzero])) * 100 if nonzero.any() else 0.0
    clean = lambda v: round(float(v), 4) if np.isfinite(v) else 0.0
    return {"mae": clean(mae), "rmse": clean(rmse), "r2": clean(r2), "mape": clean(mape)}


def _result(name, values, metrics=None, test_predictions=None, details="", error=None):
    values = [round(max(0.0, float(v)), 2) for v in values]
    m = metrics or {"mae": 0.0, "rmse": 0.0, "r2": 0.0, "mape": 0.0}
    out = {
        "model": name,
        "forecast_kg": round(float(np.mean(values)), 2),
        **m,
        "evaluated": metrics is not None,
        "forecast_values": values,
        "test_predictions": [round(float(v), 2) for v in (test_predictions or [])],
        "details": details,
    }
    if error:
        out["error"] = error
    return out


def run_all_models(data: list, block: str, periods: int = 1) -> dict:
    """Evaluate all five models under the same protocol, then forecast the
    next `periods` cycles with each model trained on ALL cycles."""
    raw = pd.DataFrame(data)
    synthetic = int((raw["notes"] == "SYNTHETIC").sum()) if "notes" in raw.columns else 0
    df = prepare_data(data)
    hist = History(df["yield_kg"].to_numpy(float), pd.DatetimeIndex(df["date"]),
                   df["weather_factor"].to_numpy(float))
    n, periods = len(hist), max(1, int(periods))

    ctx = RunContext(hist, SarimaEngine(hist))
    models = [SarimaModel(), LSTMModel(), SarimaLSTMModel(), SarimaLGBMModel(), RandomForestModel()]

    # ---- 1. Walk-forward evaluation on the held-out cycles -------------
    n_test = min(MAX_TEST, max(MIN_TEST, int(round(TEST_FRACTION * n))))
    n_train = n - n_test
    can_evaluate = n_train >= MIN_TRAIN_CYCLES
    test_preds = {m.key: [] for m in models}
    eval_errors = {}
    baselines = {}
    eval_spec = None

    if can_evaluate:
        ctx.spec = eval_spec = ctx.engine.select(n_train)
        for m in models:
            if hasattr(m, "tune"):
                try:
                    m.tune(ctx, n_train)
                except Exception as e:
                    eval_errors[m.key] = f"tuning failed: {e}"
        for t in range(n_train, n):
            target = hist.dates[t:t + 1]
            for m in models:
                if m.key in eval_errors:
                    continue
                try:
                    m.fit(ctx, t)
                    test_preds[m.key].append(max(0.0, float(m.predict(ctx, target)[0])))
                except Exception as e:
                    eval_errors[m.key] = f"failed on test cycle {t + 1}: {e}"

        y_test = hist.y[n_train:]
        naive = {
            "Last cycle": hist.y[n_train - 1:n - 1],
            "Historical average": np.array([hist.y[:t].mean() for t in range(n_train, n)]),
        }
        if n_train >= CYCLES_PER_YEAR:
            naive["Same cycle last year"] = hist.y[n_train - CYCLES_PER_YEAR:n - CYCLES_PER_YEAR]
        baselines = {k: calculate_metrics(y_test, v) for k, v in naive.items()}

    # ---- 2. Final forecast, every model trained on all cycles ----------
    # The SARIMA order chosen before the test set is kept, so the model that
    # was evaluated is exactly the model that makes the forecast.
    ctx.spec = eval_spec or ctx.engine.select(n)
    future = _future_dates(hist.dates[-1], periods)
    results = {}
    for m in models:
        metrics = None
        if can_evaluate and m.key not in eval_errors:
            metrics = calculate_metrics(hist.y[n_train:], test_preds[m.key])
        try:
            m.fit(ctx, n)
            values, details, error = m.predict(ctx, future), m.details(), eval_errors.get(m.key)
        except Exception as e:
            values, details = np.full(periods, hist.y.mean()), "Could not be trained"
            error, metrics = f"forecast failed: {e}", None
        results[m.key] = _result(m.name, values, metrics, test_preds[m.key] if metrics else None,
                                 details, error)

    # ---- 3. Best model = lowest MAE on the test cycles ------------------
    scored = [r for r in results.values() if r["evaluated"]]
    if scored:
        best = min(scored, key=lambda r: (r["mae"], r["rmse"]))
    else:
        usable = [r for r in results.values() if "error" not in r]
        best = usable[0] if usable else results["sarima"]
    best_model = best["model"]

    best_forecast = best["forecast_kg"]
    avg_historical = round(float(hist.y.mean()), 2)
    recommendations = []
    if best_forecast > avg_historical * 1.1:
        recommendations.append(f"Yield expected to increase by {round((best_forecast - avg_historical) / avg_historical * 100, 1)}% — good tapping conditions ahead.")
    elif best_forecast < avg_historical * 0.9:
        recommendations.append(f"Yield expected to decrease by {round((avg_historical - best_forecast) / avg_historical * 100, 1)}% — monitor weather conditions.")
    else:
        recommendations.append("Yield expected to remain stable.")
    if scored:
        recommendations.append(f"Best model: {best_model} (average error {best['mae']} kg per cycle on {n_test} held-out cycles)")
    else:
        recommendations.append("Not enough cycles yet to test the models; the forecast is a rough guide.")

    best_baseline = min((b["mae"] for b in baselines.values()), default=None)
    evaluation = {
        "method": ("Walk-forward one-step-ahead evaluation: each test cycle is predicted "
                   "by models re-trained only on the cycles before it."),
        "evaluated": can_evaluate,
        "n_cycles": n,
        "train_cycles": n_train if can_evaluate else n,
        "test_cycles": n_test if can_evaluate else 0,
        "test_dates": [d.strftime("%Y-%m-%d") for d in hist.dates[n_train:]] if can_evaluate else [],
        "test_actual": [round(float(v), 2) for v in hist.y[n_train:]] if can_evaluate else [],
        "selection_metric": "MAE",
        "sarima_spec": ctx.spec.describe(),
        "baselines": baselines,
        "best_beats_naive": (best["mae"] < best_baseline) if (scored and best_baseline is not None) else None,
        "synthetic_rows": synthetic,
        "data_warning": (f"{synthetic} of {len(raw)} records are marked SYNTHETIC. "
                         "These results are not findings.") if synthetic else None,
    }

    return {
        **results,
        "best_model": best_model,
        "recommendations": recommendations,
        "evaluation": evaluation,
    }
