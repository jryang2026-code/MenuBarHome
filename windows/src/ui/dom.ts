export function parseSingleElement(html: string): Element | null {
  const template = document.createElement("template");
  template.innerHTML = html.trim();
  return template.content.firstElementChild;
}

export function hasMatchingDomShape(current: Node, desired: Node): boolean {
  if (current.nodeType !== desired.nodeType) return false;
  if (current.nodeType === 3) return true;
  if (current.nodeType !== 1) return current.isEqualNode(desired);
  const currentElement = current as Element;
  const desiredElement = desired as Element;
  if (currentElement.tagName.toUpperCase() !== desiredElement.tagName.toUpperCase()) return false;
  if (currentElement.tagName.toUpperCase() === "SVG") return true;
  const currentChildren = Array.from(current.childNodes);
  const desiredChildren = Array.from(desired.childNodes);
  if (currentChildren.length !== desiredChildren.length) return false;
  return currentChildren.every((child, index) => hasMatchingDomShape(child, desiredChildren[index]!));
}

export function morphMatchingDom(current: Node, desired: Node): void {
  if (current.nodeType === 3) {
    if (current.nodeValue !== desired.nodeValue) current.nodeValue = desired.nodeValue;
    return;
  }
  if (current.nodeType !== 1) return;
  const currentElement = current as Element;
  const desiredElement = desired as Element;
  const tag = currentElement.tagName.toUpperCase();
  const isDraftOwner =
    currentElement === currentElement.ownerDocument.activeElement &&
    (tag === "INPUT" || tag === "TEXTAREA") &&
    inputKeepsDraft(currentElement as HTMLInputElement | HTMLTextAreaElement);
  for (const attr of Array.from(currentElement.attributes)) {
    if (attr.name === "value" && isDraftOwner) continue;
    if (!desiredElement.hasAttribute(attr.name)) currentElement.removeAttribute(attr.name);
  }
  for (const attr of Array.from(desiredElement.attributes)) {
    if (attr.name === "value" && isDraftOwner) continue;
    if (currentElement.getAttribute(attr.name) !== attr.value) {
      currentElement.setAttribute(attr.name, attr.value);
    }
  }
  if (tag === "SVG") {
    if (currentElement.innerHTML !== desiredElement.innerHTML) {
      currentElement.innerHTML = desiredElement.innerHTML;
    }
    return;
  }
  if (tag === "INPUT") {
    const currentInput = currentElement as HTMLInputElement;
    const desiredInput = desiredElement as HTMLInputElement;
    if (!isDraftOwner && currentInput.value !== desiredInput.value) {
      currentInput.value = desiredInput.value;
    }
    if (currentInput.checked !== desiredInput.checked) {
      currentInput.checked = desiredInput.checked;
    }
    if (currentInput.disabled !== desiredInput.disabled) {
      currentInput.disabled = desiredInput.disabled;
    }
  } else if (tag === "TEXTAREA") {
    const currentText = currentElement as HTMLTextAreaElement;
    const desiredText = desiredElement as HTMLTextAreaElement;
    if (!isDraftOwner && currentText.value !== desiredText.value) {
      currentText.value = desiredText.value;
    }
    if (currentText.disabled !== desiredText.disabled) {
      currentText.disabled = desiredText.disabled;
    }
  } else if (tag === "SELECT") {
    const currentSelect = currentElement as HTMLSelectElement;
    const desiredSelect = desiredElement as HTMLSelectElement;
    if (currentSelect.disabled !== desiredSelect.disabled) {
      currentSelect.disabled = desiredSelect.disabled;
    }
  } else if (tag === "DETAILS") {
    const currentDetails = currentElement as HTMLDetailsElement;
    const desiredDetails = desiredElement as HTMLDetailsElement;
    if (currentDetails.open !== desiredDetails.open) {
      currentDetails.open = desiredDetails.open;
    }
  }
  const currentChildren = Array.from(current.childNodes);
  const desiredChildren = Array.from(desired.childNodes);
  currentChildren.forEach((child, index) => morphMatchingDom(child, desiredChildren[index]!));
  if (tag === "SELECT") {
    const currentSelect = currentElement as HTMLSelectElement;
    const desiredSelect = desiredElement as HTMLSelectElement;
    if (currentSelect.value !== desiredSelect.value) {
      currentSelect.value = desiredSelect.value;
    }
    if (currentSelect.selectedIndex !== desiredSelect.selectedIndex && desiredSelect.selectedIndex >= 0) {
      currentSelect.selectedIndex = desiredSelect.selectedIndex;
    }
  }
}

export function inputKeepsDraft(input: HTMLInputElement | HTMLTextAreaElement): boolean {
  if (input.tagName === "TEXTAREA") return true;
  return !["button", "checkbox", "color", "file", "radio", "range", "reset", "submit"].includes(
    (input as HTMLInputElement).type,
  );
}

export function waitForCameraFrameGap(signal: AbortSignal, ms: number): Promise<void> {
  if (signal.aborted) return Promise.resolve();
  return new Promise((resolve) => {
    const finish = () => {
      window.clearTimeout(timer);
      signal.removeEventListener("abort", finish);
      resolve();
    };
    const timer = window.setTimeout(finish, ms);
    signal.addEventListener("abort", finish);
  });
}
