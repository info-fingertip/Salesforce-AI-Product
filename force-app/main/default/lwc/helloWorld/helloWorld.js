import { LightningElement } from 'lwc';

export default class HelloWorld extends LightningElement {
    name = '';

    get greeting() {
        return this.name ? `Hello, ${this.name}!` : 'Hello, World!';
    }

    handleNameChange(event) {
        this.name = event.target.value;
    }
}