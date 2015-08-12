## S2 balance sheet (unshocked)
function s2bal(p::ProjParam)
  invs = InvPort(p.t_0, p.T, p.cap_mkt, p.invs_par...)
  proj = Projection(p.tax_rate, p.tax_credit_0, p.cap_mkt, invs,
                    p.l_ins, p.l_other, p.dyn)
  bal =
    hcat(proj.val_0, DataFrame(tax_credit = proj.tax_credit_0))
  return hcat(bal, DataFrame(bof = bof(bal), scen = :be))
end

## S2 balance sheet (shocked)
function s2proj(p::ProjParam,
                md::S2Module,
                shock!::Any,
                scen::Symbol)
  cpm = deepcopy(p.cap_mkt)
  l_ins = deepcopy(p.l_ins)
  if md.shock_object ==  :CapMkt shock!(cpm, md) end
  invs = InvPort(p.t_0, p.T, cpm, p.invs_par...)
  if md.shock_object == :CapMkt_AdjVal0 shock!(invs, md) end
  if md.shock_object == :LiabIns shock!(l_ins, md) end
  if md.shock_object == :InvPort_LiabIns
    shock!(invs, l_ins, md)
  end

  proj = Projection(p.tax_rate, p.tax_credit_0, cpm, invs,
                    l_ins, p.l_other, p.dyn)
  if md.shock_object == :CapMkt_AdjVal0
    mkt_val0_adj!(proj, invs, md, scen)
  end
  return proj
end

function s2bal(p::ProjParam,
               md::S2Module,
               shock!::Any,
               scen::Symbol)
  proj = s2proj(p, md, shock!, scen)
  bal =
    hcat(proj.val_0, DataFrame(tax_credit = proj.tax_credit_0))
  return hcat(bal, DataFrame(bof = bof(bal), scen = scen))
end

## basic own funds
bof(bal::DataFrame) =
  bal[1, :invest][1,1] +
  bal[1, :tax_credit][1,1] -
  bal[1, :tpg][1,1] -
  bal[1, :cost_prov][1,1] -
  bal[1, :bonus][1,1]

bof(bal::DataFrame, scen::Symbol) =
  bof(bal[bal[:scen] .== scen, :])

bof(md::S2Module, scen::Symbol) = bof(md.balance, scen)

## future discretionary benefits
fdb(md::S2Module, scen::Symbol) =
  md.balance[md.balance[:scen] .== scen, :bonus][1,1]

## scenario based scr calculation
function scenscr!(mdl::S2Module)
  net =
    (bof(mdl, :be) .-
     Float64[bof(mdl, sm) for sm in mdl.shock_type])
  gross =
    (net .+ fdb(mdl, :be) .-
     Float64[fdb(mdl, sm) for sm in mdl.shock_type])
  if :corr in names(mdl)
    mdl.scr[NET] = sqrt(net ⋅ (mdl.corr * net))
    mdl.scr[GROSS] = sqrt(gross ⋅ (mdl.corr * gross))
  else
    i = findmax(net)[2]
    mdl.scr[NET] = max(0, net[i])
    mdl.scr[GROSS] = max(0, gross[i])
  end
end

## aggregation of scrs of sub-modules
function aggrscr(mds::Vector{S2Module}, corr::Matrix{Float64})
  scr = zeros(Float64, 2)
  net = Float64[mds[i].scr[NET] for i = 1:length(mds)]
  gross = Float64[mds[i].scr[GROSS] for i = 1:length(mds)]
  scr[GROSS] = sqrt(gross ⋅ (corr * gross))
  scr[NET] = sqrt(net ⋅ (corr * net))
  return scr
end

## S2MktInt -----------------------------------------------------
function scr!(mkt_int::S2MktInt)
  net =
    bof(mkt_int, :be) .-
  Float64[bof(mkt_int, sm) for sm in mkt_int.shock_type]
  gross =
    net .+ fdb(mkt_int, :be) -
    Float64[fdb(mkt_int, sm) for sm in mkt_int.shock_type]

  i_up = findin(mkt_int.shock_type, [:spot_up])[1]
  i_down = findin(mkt_int.shock_type, [:spot_down])[1]

  mkt_int.scen_up = net[i_up] >= net[i_down]
  mkt_int.scr[NET] = maximum([0.0, net])
  mkt_int.scr[GROSS] =
    max(0.0, mkt_int.scen_up ? gross[i_up] : gross[i_down])
end

function rfrshock(rfr::Vector{Float64}, s2_mkt_int, int_type)
  ## shock the risk free interest rate
  len = min(length(rfr),
            length(s2_mkt_int.shock[:spot_up]),
            length(s2_mkt_int.shock[:spot_down]))
  spot = forw2spot(rfr[1:len])
  if int_type == :spot_down
    forw =
      spot2forw(spot .*
                (1 .+ s2_mkt_int.shock[:spot_down][1:len]))
  elseif int_type == :spot_up
    forw =
      spot2forw(spot .+
                max(spot .* s2_mkt_int.shock[:spot_up][1:len],
                    s2_mkt_int.spot_up_abs_min))
  else # :be
      forw = spot2forw(spot)
  end
  return forw
end

function mktintshock!(cap_mkt::CapMkt,
                      s2_mkt_int,
                      int_type::Symbol)

  cap_mkt.rfr.x =
    deepcopy(rfrshock(cap_mkt.rfr.x, s2_mkt_int, int_type))
end



## S2MktEq ------------------------------------------------------
function mkteqshock!(invs::InvPort, mkt_eq, eq_type::Symbol)
#   invs = InvPort(p.t_0, p.T, cpm, p.invs_par...)

  for invest in invs.igs[:IGStock].investments
    if mkt_eq.eq2type[invest.name] == eq_type
      invest.proc.x .*= (1 + mkt_eq.shock[eq_type])
    end
  end
end

function mkt_val0_adj!(proj::Projection, invs::InvPort,
                       mkt_eq, eq_type::Symbol)
  # adjust initial market value for S2 balance sheet
  for invest in invs.igs[:IGStock].investments
    if mkt_eq.eq2type[invest.name] == eq_type
      proj.val_0[1,:invest] +=
        mkt_eq.shock[eq_type] * invest.mv_0
    end
  end
end


## S2Def1 -------------------------------------------------------
function scr!(def::S2Def1)
  var = def.tlgd ⋅ (def.u * def.tlgd) + def.v ⋅ def.slgd
  sigma_norm = -sqrt(var)/sum(def.tlgd)
  if sigma_norm <= def.scr_par[:low][1]
    def.scr[NET] = def.scr_par[:low][2] * sqrt(var)
  elseif sigma_norm <= def.scr_par[:medium][1]
    def.scr[NET] = def.scr_par[:medium][2] * sqrt(var)
  else
    def.scr[NET] = sum(def.tlgd)
  end
  def.scr[GROSS] = def.scr[NET]
end

## S2LifeBio ----------------------------------------------------
## identify those model points that are subject to mortality
## risk. This function does not properly take into account
## second order effects due to the effect of boni.
## However, for realistic portfolios second order effects are
## unlikely to change the set of identified model points.
function select!(p::ProjParam, bio::S2LifeBio)
  invs = InvPort(p.t_0, p.T, p.cap_mkt, p.invs_par...)
  for symb in bio.shock_type
    merge!(bio.mp_select,
           [symb => Array(Bool, length(p.l_ins.mps))])
    for (m, mp) in enumerate(p.l_ins.mps)
      tp = tpg(p.t_0,
               p.cap_mkt.rfr.x,
               mp)
      mp_shock = deepcopy(mp)
      bioshock!(mp_shock, bio, symb)
      tp_shock = tpg(p.t_0,
                     p.cap_mkt.rfr.x,
                     mp_shock)
      bio.mp_select[symb][m] = (tp_shock > tp)
    end
  end
end

function bioshock!(mp::ModelPoint,
                   bio::S2LifeBio,
                   symb::Symbol)
  if symb in [:qx, :px]
    qxpxshock!(mp, bio, symb)
  elseif symb in [:sx_down, :sx_up,
                  :sx_mass_pension, :sx_mass_other]
    sxshock!(mp, bio, symb)
  elseif symb in [:cat]
    catshock!(mp, bio, symb)
  end
end

function bioshock!(l_ins::LiabIns,
                   bio::S2LifeBio,
                   shock_symb::Symbol)
  for (m, mp) in enumerate(l_ins.mps)
    if bio.mp_select[shock_symb][m]
      bioshock!(mp, bio, shock_symb)
    end
  end
end

function qxpxshock!(mp::ModelPoint, bio::S2LifeBio, symb::Symbol)
  mp.prob[:qx] =
    min(1, (1 + bio.shock[symb]) * array(mp.prob[:qx]))
  mp.prob[:sx] = min(1 .- mp.prob[:qx], mp.prob[:sx])
  mp.prob[:px] =  1.0 .- mp.prob[:qx] - mp.prob[:sx]
end

function sxshock!(mp::ModelPoint, bio::S2LifeBio, symb::Symbol)
  if symb == :sx_down
    mp.prob[:sx] =
      max((1 + bio.shock[:sx_down]) * array(mp.prob[:sx]),
          array(mp.prob[:sx]) .+ bio.shock[:sx_down_threshold])
  elseif symb == :sx_up
    mp.prob[:sx] =
      min(1, (1 + bio.shock[symb]) * array(mp.prob[:sx]))
  elseif symb == :sx_mass_pension
    mp.prob[1, :sx] = bio.shock[symb]
  elseif symb == :sx_mass_other
    mp.prob[1, :sx] = bio.shock[symb]
  end
  mp.prob[:qx] = min(1 .- mp.prob[:sx], mp.prob[:qx])
  mp.prob[:px] =  1.0 .- mp.prob[:qx] - mp.prob[:sx]
end

function catshock!(mp::ModelPoint, bio::S2LifeBio, symb::Symbol)
  mp.prob[1, :qx] = min(1, mp.prob[1, :qx] + bio.shock[symb])
  mp.prob[1, :sx] = min(1 .- mp.prob[1, :qx], mp.prob[1, :sx])
  mp.prob[:px] =  1.0 .- mp.prob[:qx] - mp.prob[:sx]
end

## S2LifeCost ---------------------------------------------------
function costshock!(invs::InvPort,
                    l_ins::LiabIns,
                    cost::S2LifeCost)
  shock_eoy =
    (1 + cost.shock[:cost]) *
    (1 + cost.shock[:infl]) .^ [1:l_ins.dur]
  for symb in collect(keys(invs.igs))
    invs.igs[symb].cost.rel .*= shock_eoy
    invs.igs[symb].cost.abs .*= shock_eoy
  end
  for mp in l_ins.mps
    mp.λ[:, :boy] .*= (1 + cost.shock[:cost])
    mp.λ[:, :eoy] .*= (1 + cost.shock[:cost])
    mp.λ[:, :infl] .+= cost.shock[:infl]
    mp.λ[:, :cum_infl] =
      mp.λ[1, :cum_infl] / (1 + mp.λ[1, :infl]) *
      cumprod(1 .+ mp.λ[:, :infl])
  end
end

## S2Op ---------------------------------------------------------
function scr!(op::S2Op, bscr)
  ## SCR for operational risk
  op.comp_prem =
    op.fac[:prem] *
    (op.prem_earned +
       max(0,
           op.prem_earned -
             op.fac[:prem_py] * op.prem_earned_prev))
  op.comp_tp = op.fac[:tp]  * max(0, op.tp)
  op.scr =
    min(op.fac[:bscr] * bscr, max(op.comp_prem, op.comp_tp)) +
    op.fac[:cost] * op.cost_ul
end

## S2 -----------------------------------------------------------
function scr!(s2::S2, tax_credit_0::Float64)
  ## SCR
  s2.bscr = aggrscr(s2.mds, s2.corr)
  scr!(s2.op, s2.bscr[GROSS])
  s2.adj_dt = 0.0 ## fixme: deferred tax not implemented
  s2.adj_tp =
    -max(0.0, min(s2.bscr[GROSS] - s2.bscr[NET], fdb(s2, :be)))
  s2.adj_dt =
    -max(tax_credit_0 - (s2.bscr[GROSS] + s2.op.scr + s2.adj_tp),
         0)
  s2.scr = s2.bscr[GROSS] + s2.adj_tp + s2.adj_dt + s2.op.scr
  s2.liabs_mod =
    s2.balance[1,:tpg] +
    s2.balance[1,:bonus] +
    s2.balance[1,:cost_prov]
  s2.invest_mod =  s2.balance[1,:invest]
  s2.scr_ratio = (s2.invest_mod - s2.liabs_mod)/ s2.scr
end


