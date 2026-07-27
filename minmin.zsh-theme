#!/usr/bin/env zsh
# ============================================================================
#  minmin.zsh-theme — a minimal-but-riced prompt for oh-my-zsh
#
#  Features
#    · two-line prompt with box-drawing frame (or one-line, see MINMIN_LAYOUT)
#    · automatic light/dark background detection (OSC 11 + COLORFGBG)
#    · rich git status: branch, staged/modified/untracked/deleted/conflicts,
#      stash count, ahead/behind arrows
#    · command duration, exit status, background jobs, venv, ssh/root markers
#    · three glyph sets: nerd / unicode / ascii
#
#  Config (set any of these in ~/.zshrc BEFORE oh-my-zsh.sh is sourced)
#    MINMIN_LAYOUT=twoline|oneline      default twoline
#    MINMIN_GLYPHS=nerd|unicode|ascii   default unicode
#    MINMIN_BG=auto|light|dark          default auto
#    MINMIN_GIT=1|0                     default 1   (git segment on/off)
#    MINMIN_GIT_STATUS=1|0              default 1   (dirty-file counts on/off)
#    MINMIN_CLOCK=1|0                   default 1   (right-hand clock)
#    MINMIN_CMD_MIN_SECONDS=2                       (duration display floor)
#    MINMIN_SHOW_USER=auto|always|never default auto (auto = ssh or root)
#
#  Runtime helpers
#    minmin-bg  light|dark|auto|toggle  switch palette on the fly
#    minmin-demo                        preview the palette
# ============================================================================

setopt PROMPT_SUBST
zmodload -i zsh/datetime 2>/dev/null
autoload -Uz add-zsh-hook

: ${MINMIN_LAYOUT:=twoline}
: ${MINMIN_GLYPHS:=unicode}
: ${MINMIN_BG:=auto}
: ${MINMIN_GIT:=1}
: ${MINMIN_GIT_STATUS:=1}
: ${MINMIN_CLOCK:=1}
: ${MINMIN_CMD_MIN_SECONDS:=2}
: ${MINMIN_SHOW_USER:=auto}

export VIRTUAL_ENV_DISABLE_PROMPT=1

typeset -gA _minmin_c _minmin_g
typeset -g _minmin_mode=dark
typeset -g _minmin_cache="${XDG_CACHE_HOME:-$HOME/.cache}/minmin-bg"

# ----------------------------------------------------------------------------
# Glyphs
# ----------------------------------------------------------------------------
_minmin_set_glyphs() {
  case $MINMIN_GLYPHS in
    nerd)
      _minmin_g=(
        tl '╭─' bl '╰─' prompt '❯' branch $'\ue0a0' detached $'\uf417'
        staged '+' modified '!' untracked '?' deleted $'\uf00d' conflict '='
        stash $'\uf0c7' ahead $'\uf062' behind $'\uf063' diverged $'\uf07d'
        clean $'\uf00c' clock $'\uf017' timer $'\uf252' jobs $'\uf085'
        venv $'\ue73c' ssh $'\uf0c1' root $'\uf0e7' err $'\uf071' sep '·'
      )
      ;;
    ascii)
      _minmin_g=(
        tl '' bl '' prompt '>' branch 'git:' detached '@'
        staged '+' modified '!' untracked '?' deleted 'x' conflict '='
        stash '*' ahead '^' behind 'v' diverged 'x'
        clean 'ok' clock '' timer '' jobs 'jobs:'
        venv 'py:' ssh 'ssh' root '#' err '!' sep '|'
      )
      ;;
    *)
      _minmin_g=(
        tl '╭─' bl '╰─' prompt '❯' branch '⎇' detached '➦'
        staged '+' modified '!' untracked '?' deleted '✘' conflict '='
        stash '✱' ahead '⇡' behind '⇣' diverged '⇕'
        clean '✔' clock '' timer '⌁' jobs '⚙' venv '◈'
        ssh '⇄' root '⚡' err '✖' sep '·'
      )
      ;;
  esac
}

# ----------------------------------------------------------------------------
# Palette — two hand-tuned 256-colour sets
# ----------------------------------------------------------------------------
_minmin_set_palette() {
  if [[ $_minmin_mode == light ]]; then
    _minmin_c=(
      frame  '245'  user   '25'   at     '250'  host   '31'
      path   '26'   repo   '55'   sep    '250'  muted  '243'
      git    '28'   dirty  '130'  staged '29'   untrk  '61'
      del    '124'  conf   '160'  stash  '90'   sync   '30'
      ok     '28'   err    '124'  jobs   '94'   venv   '91'
      root   '124'  ssh    '30'   time   '244'
    )
  else
    _minmin_c=(
      frame  '240'  user   '110'  at     '240'  host   '80'
      path   '117'  repo   '141'  sep    '240'  muted  '245'
      git    '114'  dirty  '215'  staged '150'  untrk  '111'
      del    '203'  conf   '204'  stash  '183'  sync   '117'
      ok     '114'  err    '203'  jobs   '221'  venv   '147'
      root   '203'  ssh    '80'   time   '245'
    )
  fi
}

# ----------------------------------------------------------------------------
# Background detection
# ----------------------------------------------------------------------------

# True only if we can actually open a controlling terminal. A bare -r/-w test
# on /dev/tty is not enough: the node can exist while the process has no
# controlling tty, and the failing redirection would then print to stderr.
_minmin_have_tty() {
  [[ -o interactive ]] || return 1
  (( $+commands[stty] )) || return 1
  { : </dev/tty && : >>/dev/tty } 2>/dev/null
}

# Ask the terminal for its background colour via OSC 11 and judge luminance.
# Returns 0 = dark, 2 = light, 1 = could not tell.
_minmin_probe_osc() {
  _minmin_have_tty || return 1

  local stty_save resp='' c=''
  stty_save=$(stty -g 2>/dev/null </dev/tty) || return 1

  {
    stty raw -echo min 0 time 0 2>/dev/null </dev/tty
    printf '\033]11;?\033\\' 2>/dev/null >/dev/tty
    if IFS= read -r -k 1 -t 0.4 c 2>/dev/null </dev/tty; then
      resp=$c
      while IFS= read -r -k 1 -t 0.05 c 2>/dev/null </dev/tty; do
        resp+=$c
        [[ $c == $'\a' || $c == '\\' ]] && break
      done
    fi
  } always {
    stty "$stty_save" 2>/dev/null </dev/tty
  }

  [[ $resp == *rgb:* ]] || return 1

  local -a parts=( ${(s:/:)${resp#*rgb:}} )
  (( ${#parts} >= 3 )) || return 1

  local -a v=()
  local p h
  for p in ${parts[1,3]}; do
    h=${p//[^0-9a-fA-F]/}
    [[ -n $h ]] || return 1
    case ${#h} in
      1) h="${h}${h}" ;;
      2) ;;
      *) h=${h[1,2]} ;;
    esac
    v+=( $(( 16#$h )) )
  done

  (( (v[1]*299 + v[2]*587 + v[3]*114) / 1000 > 127 )) && return 2
  return 0
}

# COLORFGBG is exported by rxvt, konsole, and a few others: "fg;bg".
_minmin_probe_colorfgbg() {
  [[ -n $COLORFGBG ]] || return 1
  local bg=${COLORFGBG##*;}
  [[ $bg == <-> ]] || return 1
  (( bg == 7 || bg == 15 || bg > 231 )) && return 2
  return 0
}

_minmin_detect_bg() {
  local force=$1

  if [[ $force != force && -r $_minmin_cache ]]; then
    local cached
    read -r cached <$_minmin_cache 2>/dev/null
    case $cached in
      light|dark) _minmin_mode=$cached; return ;;
      none)       _minmin_mode=dark;    return ;;
    esac
  fi

  local result=none
  _minmin_probe_colorfgbg
  case $? in
    0) result=dark  ;;
    2) result=light ;;
    *)
      _minmin_probe_osc
      case $? in
        0) result=dark  ;;
        2) result=light ;;
      esac
      ;;
  esac

  if [[ $result == none ]]; then
    _minmin_mode=dark
    # Only remember a failure if a terminal was actually there to answer us;
    # otherwise (cron, pipe, no controlling tty) leave the cache alone so the
    # next real interactive shell gets a fresh chance to probe.
    _minmin_have_tty || return
  else
    _minmin_mode=$result
  fi
  mkdir -p ${_minmin_cache:h} 2>/dev/null && print -r -- $result >|$_minmin_cache 2>/dev/null
}

# Public switcher: `minmin-bg light`, `minmin-bg toggle`, `minmin-bg auto`, ...
minmin-bg() {
  case ${1:-} in
    light|dark)
      _minmin_mode=$1
      mkdir -p ${_minmin_cache:h} 2>/dev/null && print -r -- $1 >|$_minmin_cache 2>/dev/null
      ;;
    toggle)
      if [[ $_minmin_mode == dark ]]; then
        minmin-bg light
      else
        minmin-bg dark
      fi
      return
      ;;
    auto)
      rm -f $_minmin_cache 2>/dev/null
      _minmin_detect_bg force
      ;;
    ''|status)
      print -r -- "minmin: $_minmin_mode background"
      return
      ;;
    *)
      print -ru2 -- "usage: minmin-bg [light|dark|auto|toggle|status]"
      return 1
      ;;
  esac
  _minmin_set_palette
  print -r -- "minmin: $_minmin_mode background"
}

minmin-demo() {
  local k
  print -r -- "minmin palette — $_minmin_mode (glyphs: $MINMIN_GLYPHS)"
  for k in ${(ko)_minmin_c}; do
    print -rP -- "  %F{${_minmin_c[$k]}}████%f ${(r:8:)k} ${_minmin_c[$k]}"
  done
}

# ----------------------------------------------------------------------------
# Segments
# ----------------------------------------------------------------------------

_minmin_seg_context() {
  local out=''
  if [[ $MINMIN_SHOW_USER == always ]] ||
     [[ $MINMIN_SHOW_USER == auto && ( -n $SSH_CONNECTION || -n $SSH_TTY || $EUID -eq 0 ) ]]; then
    if (( EUID == 0 )); then
      out+="%F{${_minmin_c[root]}}${_minmin_g[root]} %n%f"
    else
      out+="%F{${_minmin_c[user]}}%n%f"
    fi
    out+="%F{${_minmin_c[at]}}@%f%F{${_minmin_c[host]}}%m%f"
    [[ -n $SSH_CONNECTION || -n $SSH_TTY ]] &&
      out+=" %F{${_minmin_c[ssh]}}${_minmin_g[ssh]}%f"
  fi
  print -r -- $out
}

# Inside a repo: "reponame/relative/path", otherwise the usual truncated %~.
_minmin_seg_path() {
  local root=${_minmin_git_root}
  if [[ -n $root ]]; then
    local rel=${PWD#$root}
    rel=${rel#/}
    local base=${root:t}
    local out="%F{${_minmin_c[repo]}}%B${base//\%/%%}%b%f"
    [[ -n $rel ]] && out+="%F{${_minmin_c[path]}}/${rel//\%/%%}%f"
    print -r -- $out
  else
    print -r -- "%F{${_minmin_c[path]}}%B%(5~|%-1~/…/%3~|%~)%b%f"
  fi
}

_minmin_seg_venv() {
  local name=''
  [[ -n $VIRTUAL_ENV ]] && name=${VIRTUAL_ENV:t}
  [[ -n $CONDA_DEFAULT_ENV ]] && name=$CONDA_DEFAULT_ENV
  [[ -n $name ]] || return
  print -r -- "%F{${_minmin_c[venv]}}${_minmin_g[venv]} ${name//\%/%%}%f"
}

# Leading space lives inside the conditional so nothing is emitted at 0 jobs.
_minmin_seg_jobs() {
  print -r -- "%(1j. %F{${_minmin_c[jobs]}}${_minmin_g[jobs]} %j%f.)"
}

# Collect git state once per prompt.
_minmin_git_collect() {
  _minmin_git_root=''
  _minmin_git_prompt=''
  (( MINMIN_GIT )) || return
  (( $+commands[git] )) || return

  # One rev-parse for both the root and the branch name. --abbrev-ref yields
  # the literal "HEAD" when detached, which is the signal to go find a sha.
  local -a rp
  rp=( ${(f)"$(command git rev-parse --show-toplevel --abbrev-ref HEAD 2>/dev/null)"} )
  [[ -n ${rp[1]} && ${rp[1]} == /* ]] || return

  local root=${rp[1]}
  _minmin_git_root=$root

  local head=${rp[2]} detached=0
  if [[ -z $head || $head == HEAD ]]; then
    head=$(command git rev-parse --short HEAD 2>/dev/null)
    if [[ -n $head ]]; then
      detached=1
    else
      # No commits yet: HEAD points at an unborn branch, so symbolic-ref still
      # knows its name even though rev-parse cannot resolve it.
      head=$(command git symbolic-ref --short HEAD 2>/dev/null) || head='HEAD'
    fi
  fi

  local out="%F{${_minmin_c[git]}}"
  (( detached )) && out+="${_minmin_g[detached]} " || out+="${_minmin_g[branch]} "
  out+="%B${head//\%/%%}%b%f"

  if (( MINMIN_GIT_STATUS )); then
    local -i staged=0 modified=0 untracked=0 deleted=0 conflicts=0 ahead=0 behind=0
    local status_out line x y
    status_out=$(command git status --porcelain --branch --untracked-files=normal 2>/dev/null)

    for line in ${(f)status_out}; do
      if [[ $line == '## '* ]]; then
        [[ $line =~ 'ahead ([0-9]+)'  ]] && ahead=$match[1]
        [[ $line =~ 'behind ([0-9]+)' ]] && behind=$match[1]
        continue
      fi
      x=${line[1]} y=${line[2]}
      case "$x$y" in
        '??')                              (( untracked++ )) ;;
        'UU'|'AA'|'DD'|'AU'|'UA'|'DU'|'UD') (( conflicts++ )) ;;
        *)
          [[ $x != ' ' ]] && (( staged++ ))
          [[ $y == [MT] ]] && (( modified++ ))
          [[ $y == 'D'  ]] && (( deleted++ ))
          ;;
      esac
    done

    # Counting the stash reflog by hand avoids forking `git stash list | wc`.
    # A .git that is not a directory means worktree/submodule, so ask git.
    local -i stashes=0
    if [[ -d $root/.git ]]; then
      if [[ -f $root/.git/logs/refs/stash ]]; then
        local -a stashlog=( ${(f)"$(<$root/.git/logs/refs/stash)"} )
        stashes=${#stashlog}
      fi
    else
      stashes=$(command git stash list 2>/dev/null | wc -l)
    fi

    local marks=''
    (( conflicts )) && marks+=" %F{${_minmin_c[conf]}}${_minmin_g[conflict]}${conflicts}%f"
    (( staged ))    && marks+=" %F{${_minmin_c[staged]}}${_minmin_g[staged]}${staged}%f"
    (( modified ))  && marks+=" %F{${_minmin_c[dirty]}}${_minmin_g[modified]}${modified}%f"
    (( deleted ))   && marks+=" %F{${_minmin_c[del]}}${_minmin_g[deleted]}${deleted}%f"
    (( untracked )) && marks+=" %F{${_minmin_c[untrk]}}${_minmin_g[untracked]}${untracked}%f"
    (( stashes ))   && marks+=" %F{${_minmin_c[stash]}}${_minmin_g[stash]}${stashes}%f"

    if (( ahead && behind )); then
      marks+=" %F{${_minmin_c[sync]}}${_minmin_g[diverged]}${ahead}/${behind}%f"
    elif (( ahead )); then
      marks+=" %F{${_minmin_c[sync]}}${_minmin_g[ahead]}${ahead}%f"
    elif (( behind )); then
      marks+=" %F{${_minmin_c[sync]}}${_minmin_g[behind]}${behind}%f"
    fi

    if [[ -z $marks ]]; then
      marks=" %F{${_minmin_c[ok]}}${_minmin_g[clean]}%f"
    fi
    out+=$marks
  fi

  _minmin_git_prompt=$out
}

# ----------------------------------------------------------------------------
# Command timing
# ----------------------------------------------------------------------------
_minmin_preexec() { _minmin_start=$EPOCHREALTIME }

_minmin_fmt_duration() {
  local -F elapsed=$1
  local -i total=${elapsed%.*}
  if (( total < 60 )); then
    printf '%.1fs' $elapsed
  elif (( total < 3600 )); then
    printf '%dm%02ds' $(( total / 60 )) $(( total % 60 ))
  else
    printf '%dh%02dm' $(( total / 3600 )) $(( (total % 3600) / 60 ))
  fi
}

# Sets _minmin_duration. Must run in the current shell, not a subshell, so the
# start timestamp is actually consumed.
_minmin_seg_duration() {
  _minmin_duration=''
  [[ -n $_minmin_start ]] || return
  local -F elapsed=$(( EPOCHREALTIME - _minmin_start ))
  unset _minmin_start
  (( elapsed >= MINMIN_CMD_MIN_SECONDS )) || return
  _minmin_duration="%F{${_minmin_c[time]}}${_minmin_g[timer]} $(_minmin_fmt_duration $elapsed)%f"
}

# ----------------------------------------------------------------------------
# Assembly
# ----------------------------------------------------------------------------
_minmin_precmd() {
  local -i last=$?

  _minmin_seg_duration
  _minmin_git_collect

  local -a parts=()
  local seg
  for seg in "$(_minmin_seg_context)" "$(_minmin_seg_path)" "$_minmin_git_prompt" \
             "$(_minmin_seg_venv)" "$_minmin_duration"; do
    [[ -n $seg ]] && parts+=("$seg")
  done

  local sepstr=" %F{${_minmin_c[sep]}}${_minmin_g[sep]}%f "
  local line1=${(pj:$sepstr:)parts}

  local jobseg="$(_minmin_seg_jobs)"

  # exit status: green arrow on success, red arrow + code on failure
  local arrow
  if (( last == 0 )); then
    arrow="%F{${_minmin_c[ok]}}${_minmin_g[prompt]}%f"
  else
    arrow="%F{${_minmin_c[err]}}${_minmin_g[err]} ${last} ${_minmin_g[prompt]}%f"
  fi

  if [[ $MINMIN_LAYOUT == oneline ]]; then
    PROMPT="${line1}${jobseg} ${arrow} "
  else
    PROMPT=$'\n'"%F{${_minmin_c[frame]}}${_minmin_g[tl]}%f ${line1}${jobseg}"$'\n'
    PROMPT+="%F{${_minmin_c[frame]}}${_minmin_g[bl]}%f ${arrow} "
  fi

  if (( MINMIN_CLOCK )); then
    RPROMPT="%F{${_minmin_c[time]}}${_minmin_g[clock]:+${_minmin_g[clock]} }%D{%H:%M:%S}%f"
  else
    RPROMPT=''
  fi

  PS2="%F{${_minmin_c[frame]}}${_minmin_g[bl]}%f %F{${_minmin_c[muted]}}%_%f ${_minmin_g[prompt]} "
  RPS2=''
}

_minmin_set_glyphs

case $MINMIN_BG in
  light|dark) _minmin_mode=$MINMIN_BG ;;
  *)          _minmin_detect_bg ;;
esac

_minmin_set_palette

add-zsh-hook preexec _minmin_preexec
add-zsh-hook precmd  _minmin_precmd

# Populate PROMPT immediately so anything inspecting it before the first
# precmd fires (or `zsh -i -c ...`) sees the real thing, not zsh's default.
_minmin_precmd
